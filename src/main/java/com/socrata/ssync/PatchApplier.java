package com.socrata.ssync;

import com.socrata.ssync.exceptions.input.ChecksumMismatch;
import com.socrata.ssync.exceptions.input.InputException;
import com.socrata.ssync.exceptions.patch.*;

import java.io.*;
import java.util.zip.Inflater;

public class PatchApplier {
    public static void apply(BlockFinder blockFinder, InputStream patch, OutputStream target) throws IOException, PatchException, InputException {
        new PatchApplier(blockFinder, patch, target).go();
    }

    private final InputStreamReadHelper in;
    private final BlockFinder blockFinder;
    private final OutputStream target;
    private final int blockSize;
    private final byte[] dataBuf;

    private PatchApplier(BlockFinder blockFinder, InputStream patch, OutputStream target) throws IOException, PatchException, InputException {
        this.in = new InputStreamReadHelper(patch, InputStreamReadHelper.readChecksumAlgorithm(patch));
        this.blockFinder = blockFinder;
        this.target = target;

        blockSize = in.readInt();
        if(blockSize <= 0 || blockSize > Patch.MaxBlockSize) throw new InvalidBlockSize(blockSize);
        dataBuf = new byte[blockSize];
    }

    private void go() throws IOException, InputException, PatchException {
        mainloop();
        byte[] result = in.checksum();
        byte[] checksumInPatch = new byte[result.length];
        in.readFullyWithoutUpdatingChecksum(checksumInPatch);
        if(!java.util.Arrays.equals(result, checksumInPatch)) throw new ChecksumMismatch();
    }

    private void mainloop() throws IOException, PatchException, InputException {
        int code;
        while((code = readOp()) != Patch.End) {
            switch(code) {
            case Patch.Block:
                processBlock();
                break;
            case Patch.Data:
                processData();
                break;
            default:
                throw new UnknownOp(code);
            }
        }
    }

    private void processBlock() throws IOException, PatchException, InputException {
        long blockNum = in.readInt();
        long blockStart = blockNum * blockSize;
        if(blockNum >= 0 && blockStart + blockSize - 1 >= 0) {
            blockFinder.getBlock(blockStart, blockSize, target);
        } else {
            throw new NoSuchBlock(blockNum);
        }
    }

    private void processData() throws IOException, PatchException, InputException {
        int len = in.readInt();
        if(len <= 0 || len > dataBuf.length) throw new InvalidDataBlockLength(len);
        in.readBytes(dataBuf, len);
        target.write(dataBuf, 0, len);
    }

    private int readOp() throws IOException, InputException {
        return in.readByte() & 0xff;
    }
}
