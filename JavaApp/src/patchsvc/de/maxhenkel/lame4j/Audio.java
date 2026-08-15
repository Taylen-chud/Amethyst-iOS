package de.maxhenkel.lame4j;

import javax.sound.sampled.AudioFormat;

public interface Audio {

    int getChannelCount();

    int getSampleRate();

    int getBitRate();

    /**
     * @return the sample size of the decoded audio in bytes
     */
    default int getSampleSizeInBytes() {
        return 2;
    }

    /**
     * @return the sample size of the decoded audio in bits
     */
    default int getSampleSizeInBits() {
        return getSampleSizeInBytes() * 8;
    }

    /**
     * Creates an AudioFormat object for the decoded audio.
     *
     * @return the audio format of the decoded audio
     */
    default AudioFormat createAudioFormat() {
        return new AudioFormat(AudioFormat.Encoding.PCM_SIGNED, getSampleRate(), getSampleSizeInBits(), getChannelCount(), getSampleSizeInBytes() * getChannelCount(), getSampleRate(), false);
    }

}
