package de.maxhenkel.lame4j;

import java.util.Arrays;

public class ShortArrayBuffer {

    protected short[] buf;

    protected int count;

    public ShortArrayBuffer() {
        this(32);
    }

    public ShortArrayBuffer(int size) {
        if (size < 0) {
            throw new IllegalArgumentException("Negative initial size: " + size);
        }
        buf = new short[size];
    }

    private void ensureCapacity(int minCapacity) {
        int oldCapacity = buf.length;
        int minGrowth = minCapacity - oldCapacity;
        if (minGrowth > 0) {
            buf = Arrays.copyOf(buf, newLength(oldCapacity, minGrowth, oldCapacity));
        }
    }

    public static final int SOFT_MAX_ARRAY_LENGTH = Integer.MAX_VALUE - 8;

    private static int newLength(int oldLength, int minGrowth, int prefGrowth) {
        int prefLength = oldLength + Math.max(minGrowth, prefGrowth);
        if (0 < prefLength && prefLength <= SOFT_MAX_ARRAY_LENGTH) {
            return prefLength;
        } else {
            return hugeLength(oldLength, minGrowth);
        }
    }

    private static int hugeLength(int oldLength, int minGrowth) {
        int minLength = oldLength + minGrowth;
        if (minLength < 0) {
            throw new OutOfMemoryError("Required array length " + oldLength + " + " + minGrowth + " is too large");
        } else if (minLength <= SOFT_MAX_ARRAY_LENGTH) {
            return SOFT_MAX_ARRAY_LENGTH;
        } else {
            return minLength;
        }
    }

    public synchronized void write(short s) {
        ensureCapacity(count + 1);
        buf[count] = s;
        count += 1;
    }

    public synchronized void write(short[] b, int off, int len) {
        assert off + len <= b.length;
        ensureCapacity(count + len);
        System.arraycopy(b, off, buf, count, len);
        count += len;
    }

    public void writeShorts(short[] b) {
        write(b, 0, b.length);
    }

    public synchronized void reset() {
        count = 0;
    }

    public synchronized short[] toShortArray() {
        return Arrays.copyOf(buf, count);
    }

    public synchronized int size() {
        return count;
    }

}

