package com.sov.frostbridge;
public class SovRsaSignatureSha384 extends SovRsaSignature {
    @Override protected String ceremonyAlg() { return "RSA-SHA384"; }
}
