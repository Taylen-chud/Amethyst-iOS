package de.maxhenkel.lame4j;

import javax.sound.sampled.AudioFormat;

public class DecodedAudio implements Audio {
    private final int channelCount;
    private final int sampleRate;
    private final int bitRate;
    private final short[] samples;

    public DecodedAudio(int channelCount, int sampleRate, int bitRate, short[] samples) {
        this.channelCount = channelCount;
        this.sampleRate = sampleRate;
        this.bitRate = bitRate;
        this.samples = samples;
    }

    @Override
    public int getChannelCount() {
        return channelCount;
    }

    @Override
    public int getSampleRate() {
        return sampleRate;
    }

    @Override
    public int getBitRate() {
        return bitRate;
    }

    public short[] getSamples() {
        return samples;
    }

    @Override
    public AudioFormat createAudioFormat() {
        return new AudioFormat(AudioFormat.Encoding.PCM_SIGNED, sampleRate, getSampleSizeInBits(), channelCount, getSampleSizeInBytes() * channelCount, sampleRate, false);
    }
}
