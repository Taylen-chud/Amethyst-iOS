package de.maxhenkel.lame4j;

import javax.annotation.Nullable;
import javax.sound.sampled.AudioFormat;
import java.io.IOException;
import java.io.InputStream;

public class Mp3Decoder implements Audio, AutoCloseable {

    private long pointer;
    private final InputStream inputStream;
    private final byte[] inBuffer;
    private final byte[] leftoverBuffer;
    private int leftoverBufferLength;
    private final short[] outBuffer;

    public Mp3Decoder(InputStream inputStream) throws IOException {
        synchronized (Mp3Decoder.class) {
            System.load(System.getenv("BUNDLE_PATH") + "/Frameworks/svc/liblame4j.dylib");
            pointer = createDecoder0();
            this.inputStream = inputStream;
            inBuffer = new byte[16 * 1024];
            leftoverBuffer = new byte[16 * 1024];
            leftoverBufferLength = 0;
            outBuffer = new short[getMaxSamplesPerFrame0()];
        }
    }

    private static native long createDecoder0();

    private static native int getMaxSamplesPerFrame0();

    private native long decodeNextFrame0(long decoderPointer, byte[] input, int inputLength, short[] output) throws IOException;

    /**
     * Decodes the next frame in the mp3 file and returns the decoded audio data as PCM samples.
     * If the header of the mp3 file is not yet parsed, this method will parse the header.
     * <br/>
     * <b>NOTE</b>: If the mp3 file is invalid, the first frame will immediately return <code>null</code>.
     *
     * @return the decoded audio data as PCM samples or <code>null</code> if the end of the mp3 file is reached
     * @throws IOException if an I/O error occurs
     */
    public short[] decodeNextFrame() throws IOException {
        synchronized (this) {
            System.arraycopy(leftoverBuffer, 0, inBuffer, 0, leftoverBufferLength);
            int bytesRead = inputStream.read(inBuffer, leftoverBufferLength, inBuffer.length - leftoverBufferLength);
            if (bytesRead < 0) {
                if (leftoverBufferLength <= 0) {
                    return null;
                }
                bytesRead = 0;
            }
            int bytesToUse = leftoverBufferLength + bytesRead;
            long result = decodeNextFrame0(pointer, inBuffer, bytesToUse, outBuffer);
            int samplesDecoded = (int) (result >> 32);
            int bytesToAdvance = (int) result;
            short[] samples = new short[samplesDecoded];
            System.arraycopy(outBuffer, 0, samples, 0, samplesDecoded);
            leftoverBufferLength = bytesToUse - bytesToAdvance;
            System.arraycopy(inBuffer, bytesToAdvance, leftoverBuffer, 0, leftoverBufferLength);
            return samples;
        }
    }

    /**
     * @return if the header of the mp3 file is parsed
     */
    public boolean headerParsed() {
        synchronized (this) {
            return getChannelCount0(pointer) >= 0 && getSampleRate0(pointer) >= 0 && getBitRate0(pointer) >= 0;
        }
    }

    private native int getChannelCount0(long decoderPointer);

    /**
     * @return the number of channels of the decoded audio or -1 if the header of the mp3 file is not yet parsed
     */
    public int getChannelCount() {
        synchronized (this) {
            return getChannelCount0(pointer);
        }
    }

    private native int getBitRate0(long decoderPointer);

    /**
     * @return the bitrate of the mp3 file or -1 if the header of the mp3 file is not yet parsed
     */
    public int getBitRate() {
        synchronized (this) {
            return getBitRate0(pointer);
        }
    }

    private native int getSampleRate0(long decoderPointer);

    /**
     * @return the sample rate of the decoded audio or -1 if the header of the mp3 file is not yet parsed
     */
    public int getSampleRate() {
        synchronized (this) {
            return getSampleRate0(pointer);
        }
    }

    /**
     * Creates an AudioFormat object for the decoded audio.
     *
     * @return the audio format of the decoded audio or null if the header of the mp3 file is not yet parsed
     */
    @Override
    @Nullable
    public AudioFormat createAudioFormat() {
        if (!headerParsed()) {
            return null;
        }
        return Audio.super.createAudioFormat();
    }

    private native void destroyDecoder0(long decoderPointer);

    @Override
    public void close() throws IOException {
        synchronized (this) {
            destroyDecoder0(pointer);
            pointer = 0L;
            inputStream.close();
        }
    }

    public boolean isClosed() {
        synchronized (this) {
            return pointer == 0L;
        }
    }

    /**
     * Decodes the mp3 file and returns the decoded audio data.
     *
     * @param inputStream the input stream of the mp3 file
     * @return the decoded audio data as PCM samples
     * @throws IOException              if an I/O error occurs or the mp3 file is invalid
     * @throws UnknownPlatformException if the platform is not supported
     */
    public static DecodedAudio decode(InputStream inputStream) throws IOException {
        try (Mp3Decoder decoder = new Mp3Decoder(inputStream)) {
            ShortArrayBuffer sampleBuffer = new ShortArrayBuffer(2048);
            while (true) {
                short[] samples = decoder.decodeNextFrame();
                if (samples == null) {
                    if (sampleBuffer.size() <= 0) {
                        throw new IOException("No audio data found");
                    }
                    break;
                }
                sampleBuffer.writeShorts(samples);
            }
            if (!decoder.headerParsed()) {
                throw new IOException("No header found");
            }
            return new DecodedAudio(decoder.getChannelCount(), decoder.getSampleRate(), decoder.getBitRate(), sampleBuffer.toShortArray());
        }
    }

}
