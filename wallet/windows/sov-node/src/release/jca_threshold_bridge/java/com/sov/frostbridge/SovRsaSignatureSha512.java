package com.sov.frostbridge;
public class SovRsaSignatureSha512 extends SovRsaSignature {
    @Override protected String ceremonyAlg() { return "RSA-SHA512"; }
}
