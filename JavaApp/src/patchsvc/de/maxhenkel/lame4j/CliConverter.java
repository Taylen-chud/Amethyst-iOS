package de.maxhenkel.lame4j;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;

public class CliConverter {

    public static void main(String[] args) throws IOException {
        if (args.length < 2) {
            System.out.println("Usage: java -jar lame4j.jar <input file> <output file>");
            return;
        }
        DecodedAudio decodedAudio = Mp3Decoder.decode(Files.newInputStream(Paths.get(args[0])));

        short[] decode = decodedAudio.getSamples();

        System.out.println("Sample Rate: " + decodedAudio.getSampleRate());
        System.out.println("Bit Rate: " + decodedAudio.getBitRate());
        System.out.println("Channels: " + decodedAudio.getChannelCount());
        System.out.println("Frame Size: " + decodedAudio.getSampleSizeInBits());

        System.out.println("Length: " + decode.length + " samples");
        System.out.println("Duration: " + ((float) decode.length / (float) decodedAudio.getSampleRate()) + " seconds");

        Mp3Encoder encoder = new Mp3Encoder(decodedAudio.getChannelCount(), decodedAudio.getSampleRate(), decodedAudio.getBitRate(), 5, Files.newOutputStream(Paths.get(args[1])));
        encoder.write(decode);
        encoder.close();
    }

}
