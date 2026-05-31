package de.maxhenkel.opus4j;

import javax.annotation.Nullable;
import java.io.IOException;

public class OpusDecoder implements AutoCloseable {

    private long decoder;

    /**
     * Creates a new Opus decoder.
     *
     * @param sampleRate the sample rate (8000, 12000, 16000, 24000, or 48000)
     * @param channels   the number of channels (1 or 2)
     * @throws UnknownPlatformException if the operating system is not supported
     * @throws IOException              if the native library could not be extracted
     */
    public OpusDecoder(int sampleRate, int channels) throws IOException {
        synchronized (OpusDecoder.class) {
            System.load(System.getenv("BUNDLE_PATH") + "/Frameworks/svc/libopus4j.dylib");
            decoder = createDecoder0(sampleRate, channels);
        }
    }

    private static native String getOpusVersion0();

    public String getOpusVersion() {
        synchronized (this) {
            return getOpusVersion0();
        }
    }

    private static native long createDecoder0(int sampleRate, int channels) throws IOException;

    private native void setFrameSize0(long decoderPointer, int frameSize);

    public void setFrameSize(int frameSize) {
        synchronized (this) {
            setFrameSize0(decoder, frameSize);
        }
    }

    private native int getFrameSize0(long decoderPointer);

    public int getFrameSize() {
        synchronized (this) {
            return getFrameSize0(decoder);
        }
    }

    private native short[] decode0(long decoderPointer, @Nullable byte[] input, boolean fec);

    /**
     * Decodes the provided packet.
     *
     * @param input the input packet or <code>null</code> to do PLC
     * @param fec   whether to do PLC
     * @return the decoded audio
     * @deprecated use {@link #decode(byte[])} with <code>null</code> to do PLC
     */
    @Deprecated
    public short[] decode(@Nullable byte[] input, boolean fec) {
        synchronized (this) {
            return decode0(decoder, input, fec);
        }
    }

    /**
     * Decodes the provided packet.
     *
     * @param input the input packet or <code>null</code> to do PLC
     * @return the decoded audio
     */
    public short[] decode(@Nullable byte[] input) {
        return decode(input, false);
    }

    /**
     * @return a PLC frame
     * @deprecated use {@link #decode(byte[])} with <code>null</code> to do PLC
     */
    @Deprecated
    public short[] decodeFec() {
        return decode(null, true);
    }

    private native short[][] decodeRecover0(long decoderPointer, byte[] input, int frames);

    /**
     * Decodes the provided packet and recovers previous lost frames using FEC.
     * <br>
     * Note that you need to set {@link OpusEncoder#setMaxPacketLossPercentage(float)}
     * to a non-zero value to enable FEC, otherwise PLC will be used.
     *
     * <br>
     * If {@param frames} is 1, only the current frame will be decoded.
     * <br>
     * If {@param frames} is 2, the previous frame will be recovered using in-band FEC (if enabled).
     * <br>
     * If {@param frames} is >=3, all frames other than the current and last frame will use PLC.
     *
     * @param input  the input packet
     * @param frames the number of frames to return (min 1 for just the current frame)
     * @return an array containing the decoded frames - the length of the array is equal to {@param frames}
     */
    public short[][] decode(byte[] input, int frames) {
        synchronized (this) {
            return decodeRecover0(decoder, input, frames);
        }
    }

    private native void resetState0(long decoderPointer);

    public void resetState() {
        synchronized (this) {
            resetState0(decoder);
        }
    }

    private native void destroyDecoder0(long decoderPointer);

    @Override
    public void close() {
        synchronized (this) {
            destroyDecoder0(decoder);
            decoder = 0L;
        }
    }

    public boolean isClosed() {
        synchronized (this) {
            return decoder == 0L;
        }
    }

    @Override
    public String toString() {
        synchronized (this) {
            return String.format("OpusDecoder[%d]", decoder);
        }
    }
}
