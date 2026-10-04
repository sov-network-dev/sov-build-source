package com.sov.frostbridge;

import java.security.PrivateKey;

/** Opaque handle standing in for a private key apksigner never actually sees.
 * getEncoded() returns null (the PrivateKey/Key contract's documented way to
 * signal "opaque, no standard byte encoding") so nothing downstream can
 * accidentally serialize or log real key material — there isn't any here. */
public class SovProxyPrivateKey implements PrivateKey {
    private final String alias;
    public SovProxyPrivateKey(String alias) { this.alias = alias; }
    public String getAlias() { return alias; }
    @Override public String getAlgorithm() { return "RSA"; }
    @Override public String getFormat() { return null; }
    @Override public byte[] getEncoded() { return null; }
}
