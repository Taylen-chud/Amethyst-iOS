package de.maxhenkel.opus4j;

import java.io.IOException;

public class OpusEncoder implements AutoCloseable {

    private long encoder;

    /**
     * Creates a new Opus encoder.
     *
     * @param sampleRate  the sample rate (8000, 12000, 16000, 24000, or 48000)
     * @param channels    the number of channels (1 or 2)
     * @param application the application (VOIP, AUDIO, or LOW_DELAY)
     * @throws UnknownPlatformException if the operating system is not supported
     * @throws IOException              if the native library could not be extracted
     */
    public OpusEncoder(int sampleRate, int channels, Application application) throws IOException {
        System.load(System.getenv("BUNDLE_PATH") + "/Frameworks/svc/libopus4j.dylib");
        encoder = createEncoder0(sampleRate, channels, application);
    }

    private static native String getOpusVersion0();

    public String getOpusVersion() {
        synchronized (this) {
            return getOpusVersion0();
        }
    }

    private static native long createEncoder0(int sampleRate, int channels, Application application) throws IOException;

    private native void setMaxPayloadSize0(long encoderPointer, int maxPayloadSize);

    public void setMaxPayloadSize(int maxPayloadSize) {
        synchronized (this) {
            setMaxPayloadSize0(encoder, maxPayloadSize);
        }
    }

    private native int getMaxPayloadSize0(long encoderPointer);

    public int getMaxPayloadSize() {
        synchronized (this) {
            return getMaxPayloadSize0(encoder);
        }
    }

    private native void setMaxPacketLossPercentage0(long encoderPointer, float maxPacketLossPercentage);

    public void setMaxPacketLossPercentage(float maxPacketLossPercentage) {
        synchronized (this) {
            setMaxPacketLossPercentage0(encoder, maxPacketLossPercentage);
        }
    }

    private native float getMaxPacketLossPercentage0(long encoderPointer);

    public float getMaxPacketLossPercentage() {
        synchronized (this) {
            return getMaxPacketLossPercentage0(encoder);
        }
    }

    private native byte[] encode0(long encoderPointer, short[] input);

    public byte[] encode(short[] input) {
        synchronized (this) {
            return encode0(encoder, input);
        }
    }

    private native void resetState0(long encoderPointer);

    public void resetState() {
        synchronized (this) {
            resetState0(encoder);
        }
    }

    private native void destroyEncoder0(long encoderPointer);

    @Override
    public void close() {
        synchronized (this) {
            destroyEncoder0(encoder);
            encoder = 0L;
        }
    }

    public boolean isClosed() {
        synchronized (this) {
            return encoder == 0L;
        }
    }

    @Override
    public String toString() {
        synchronized (this) {
            return String.format("OpusEncoder[%d]", encoder);
        }
    }

    public static enum Application {
        VOIP(0),
        AUDIO(1),
        LOW_DELAY(2);

        private final int value;

        Application(int value) {
            this.value = value;
        }
    }

}
