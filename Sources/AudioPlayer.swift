import AVFoundation

/// Plays the mirrored phone audio on this Mac.
///
/// Wire format (reverse-engineered from the phone's `AACEncoder` / `PcTransportManager`):
/// the phone encodes system audio as **AAC-LC** and prepends a 7-byte **ADTS**
/// header to every access unit, then writes it as a binary message on the *same*
/// mirror WS as video. The core demuxes those out (`is_audio_frame`) and hands us
/// one ADTS packet at a time.
///
/// While it streams audio the phone mutes its own speaker (`phone_mute=true` in
/// its `AudioRecordManager`), which is why the official client sounds the way it
/// does — the Mac becomes the only output. So a failure here means the audio is
/// gone entirely, not merely duplicated: every failure path below logs.
///
/// Threading: `feed(_:)` is called only from the mirror's `audio-pump` thread;
/// `stop()` comes from the session queue. A lock guards the shared state.
final class MirrorAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var running = false
    private var stopped = false
    private var decodeFailures = 0
    // Tallied for the one-line summary on stop — the quickest way to tell "no
    // sound" apart from "sound never arrived" in a captured log.
    private var decoded = 0
    private var droppedBacklog = 0

    /// Buffers handed to the player but not finished playing. AAC packets are 1024
    /// samples (~23ms), so this caps the queue at roughly a second: if the Mac
    /// stalls (device switch, app suspend) we drop rather than let the phone's
    /// audio drift permanently behind its picture.
    private var pending = 0
    private let maxPending = 40

    /// Decode one ADTS-framed AAC packet and queue it for playback.
    func feed(_ packet: Data) {
        guard let adts = ADTSHeader(packet) else {
            lock.lock(); let n = decodeFailures; decodeFailures += 1; lock.unlock()
            if n == 0 { log("audio: not an ADTS packet (\(packet.count) bytes) — dropping") }
            return
        }
        lock.lock()
        if stopped { lock.unlock(); return }
        if converter == nil, !startEngineLocked(adts) { lock.unlock(); return }
        guard let converter, let inFormat = inputFormat, let outFormat = outputFormat else {
            lock.unlock(); return
        }
        let backlogged = pending >= maxPending
        if backlogged { droppedBacklog += 1 }
        lock.unlock()
        if backlogged { return }

        // CoreAudio wants the raw access unit plus a packet description; the ADTS
        // header is framing for the wire, not part of the AU.
        let au = packet.subdata(in: adts.headerLength ..< packet.count)
        guard !au.isEmpty else { return }
        let compressed = AVAudioCompressedBuffer(
            format: inFormat, packetCapacity: 1, maximumPacketSize: au.count
        )
        au.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(compressed.data, base, au.count) }
        }
        compressed.byteLength = UInt32(au.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(au.count)
        )

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 2048) else { return }
        var served = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if served { outStatus.pointee = .noDataNow; return nil }
            served = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else {
            lock.lock(); let n = decodeFailures; decodeFailures += 1; lock.unlock()
            if n == 0 { log("audio: AAC decode failed: \(error?.localizedDescription ?? "no data")") }
            return
        }

        lock.lock(); pending += 1; decoded += 1; lock.unlock()
        player.scheduleBuffer(pcm) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }

    /// Stop playback and release the engine. Safe to call more than once.
    func stop() {
        lock.lock()
        stopped = true
        let wasRunning = running
        running = false
        converter = nil
        let (played, dropped, failed) = (decoded, droppedBacklog, decodeFailures)
        lock.unlock()
        guard wasRunning else { return }
        player.stop()
        engine.stop()
        log("audio: playback stopped (played \(played), dropped \(dropped), failed \(failed))")
    }

    /// Packets decoded and queued so far — playback actually happened iff this rises.
    var decodedPackets: Int {
        lock.lock(); defer { lock.unlock() }; return decoded
    }

    /// Silence this Mac without touching the phone. Distinct from routing the audio
    /// back to the phone (`set_audio_to_pc`): the phone stays muted and keeps
    /// streaming, so *nothing* plays anywhere — which is the point of a local mute.
    /// Decoding continues, so unmuting resumes instantly and in sync.
    var muted: Bool = false {
        didSet {
            guard muted != oldValue else { return }
            engine.mainMixerNode.outputVolume = muted ? 0 : 1
        }
    }

    /// Build the decoder + audio graph from the first packet's ADTS header (the
    /// phone encodes 44.1kHz stereo, but it honours a request override, so the
    /// stream — not an assumption — defines the format). Caller holds `lock`.
    private func startEngineLocked(_ adts: ADTSHeader) -> Bool {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(adts.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,   // one AAC-LC access unit
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(adts.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let inFormat = AVAudioFormat(streamDescription: &asbd),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: Double(adts.sampleRate),
                                            channels: AVAudioChannelCount(adts.channels)),
              let conv = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            log("audio: cannot build an AAC decoder for \(adts.sampleRate)Hz/\(adts.channels)ch")
            return false
        }
        engine.attach(player)
        // Connecting at the stream's own rate lets the engine resample to whatever
        // the Mac's output device runs at (commonly 48kHz vs the phone's 44.1kHz).
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        engine.prepare()
        engine.mainMixerNode.outputVolume = muted ? 0 : 1   // a mute set before the first packet
        do {
            try engine.start()
        } catch {
            log("audio: engine failed to start: \(error.localizedDescription)")
            return false
        }
        player.play()
        converter = conv
        inputFormat = inFormat
        outputFormat = outFormat
        running = true
        log("audio: playing AAC \(adts.sampleRate)Hz \(adts.channels)ch (phone is muted while streaming)")
        return true
    }
}

/// The fields we need out of a 7/9-byte ADTS header.
private struct ADTSHeader {
    let sampleRate: Int
    let channels: Int
    /// 7 bytes, or 9 when the (unused by the phone) CRC is present.
    let headerLength: Int

    private static let rates = [96000, 88200, 64000, 48000, 44100, 32000,
                                24000, 22050, 16000, 12000, 11025, 8000, 7350]

    init?(_ d: Data) {
        guard d.count > 7 else { return nil }
        let b = [UInt8](d.prefix(4))
        // syncword 0xFFF + layer == 00
        guard b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 else { return nil }
        let rateIndex = Int((b[2] >> 2) & 0x0F)
        guard rateIndex < Self.rates.count else { return nil }
        let ch = Int(((b[2] & 0x01) << 2) | (b[3] >> 6))
        guard ch >= 1, ch <= 2 else { return nil }   // the phone sends mono or stereo
        sampleRate = Self.rates[rateIndex]
        channels = ch
        headerLength = (b[1] & 0x01) == 1 ? 7 : 9    // protection_absent → no CRC
    }
}
