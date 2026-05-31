package de.maxhenkel.speex4j;

import java.io.IOException;

public class AutomaticGainControl implements AutoCloseable {

    private long pointer;

    public AutomaticGainControl(int frameSize, int sampleRate) throws IOException {
        synchronized (AutomaticGainControl.class) {
            System.load(System.getenv("BUNDLE_PATH") + "/Frameworks/svc/libspeex4j.dylib");
        }
        pointer = createAgc0(frameSize, sampleRate);
    }

    private static native long createAgc0(int frameSize, int sampleRate);

    private native void setTarget0(long agcPointer, int target);

    /**
     * @param target the target linear PCM amplitude (1..32768)
     * @throws RuntimeException         if the instance is closed or an error occurred
     * @throws IllegalArgumentException if the target is out of range
     */
    public void setTarget(int target) {
        synchronized (this) {
            setTarget0(pointer, target);
        }
    }

    private native int getTarget0(long agcPointer);

    /**
     * @return the target linear PCM amplitude (1..32768)
     */
    public int getTarget() {
        synchronized (this) {
            return getTarget0(pointer);
        }
    }

    private native void setMaxGain0(long agcPointer, int maxGain);

    /**
     * @param maxGain the maximum gain that is allowed to be applied (>=0)
     * @throws RuntimeException         if the instance is closed or an error occurred
     * @throws IllegalArgumentException if the target is out of range
     */
    public void setMaxGain(int maxGain) {
        synchronized (this) {
            setMaxGain0(pointer, maxGain);
        }
    }

    private native int getMaxGain0(long agcPointer);

    /**
     * @return the maximum gain that is allowed to be applied (>=0)
     */
    public int getMaxGain() {
        synchronized (this) {
            return getMaxGain0(pointer);
        }
    }

    private native void setIncrement0(long agcPointer, int increment);

    /**
     * @param increment the maximum allowed increase in gain in dB/second (>=0)
     * @throws RuntimeException         if the instance is closed or an error occurred
     * @throws IllegalArgumentException if the target is out of range
     */
    public void setIncrement(int increment) {
        synchronized (this) {
            setIncrement0(pointer, increment);
        }
    }

    private native int getIncrement0(long agcPointer);

    /**
     * @return the maximum allowed increase in gain in dB/second (>=0)
     */
    public int getIncrement() {
        synchronized (this) {
            return getIncrement0(pointer);
        }
    }

    private native void setDecrement0(long agcPointer, int decrement);

    /**
     * @param decrement the maximum allowed decrease in gain in dB/second (&lt;=0)
     * @throws RuntimeException         if the instance is closed or an error occurred
     * @throws IllegalArgumentException if the target is out of range
     */
    public void setDecrement(int decrement) {
        synchronized (this) {
            setDecrement0(pointer, decrement);
        }
    }

    private native int getDecrement0(long agcPointer);

    /**
     * @return the maximum allowed decrease in gain in dB/second (>=0)
     */
    public int getDecrement() {
        synchronized (this) {
            return getDecrement0(pointer);
        }
    }

    private native void setVadProbStart0(long agcPointer, int probStart);

    /**
     * @param probStart the probability required to switch to speech in percent (0..100)
     * @throws RuntimeException         if the instance is closed or an error occurred
     * @throws IllegalArgumentException if the target is out of range
     */
    public void setVadProbStart(int probStart) {
        synchronized (this) {
            setVadProbStart0(pointer, probStart);
        }
    }

    private native int getVadProbStart0(long agcPointer);

    /**
     * @return the probability required to switch to speech in percent (0..100)
     */
    public int getVadProbStart() {
        synchronized (this) {
            return getVadProbStart0(pointer);
        }
    }

    private native void setVadProbContinue0(long agcPointer, int probContinue);

    /**
     * @param probContinue the probability required to stay in speech in percent (0..100)
     * @throws RuntimeException         if the instance is closed or an error occurred
     * @throws IllegalArgumentException if the target is out of range
     */
    public void setVadProbContinue(int probContinue) {
        synchronized (this) {
            setVadProbContinue0(pointer, probContinue);
        }
    }

    private native int getVadProbContinue0(long agcPointer);

    /**
     * @return the probability required to stay in speech in percent (0..100)
     */
    public int getVadProbContinue() {
        synchronized (this) {
            return getVadProbContinue0(pointer);
        }
    }

    private native boolean agc0(long agcPointer, short[] input);

    /**
     * Adjusts the gain of the audio data.
     * Modifies the audio data in-place.
     *
     * @param input The audio data
     * @return if a voice was detected
     * @throws RuntimeException if the instance is closed or an error occurred
     */
    public boolean agc(short[] input) {
        synchronized (this) {
            return agc0(pointer, input);
        }
    }

    private native void destroyAgc0(long agcPointer);

    /**
     * Closes the instance
     */
    @Override
    public void close() {
        synchronized (this) {
            destroyAgc0(pointer);
            pointer = 0L;
        }
    }

    /**
     * @return if the instance is closed
     */
    public boolean isClosed() {
        synchronized (this) {
            return pointer == 0L;
        }
    }

}
