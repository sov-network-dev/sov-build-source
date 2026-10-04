package com.sov.frostbridge;

import java.io.*;
import java.security.*;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.util.*;

/** Minimal read-only KeyStoreSpi: one alias, whose certificate is real (public,
 * loaded from disk) and whose "key" is the opaque SovProxyPrivateKey handle.
 * Everything mutating throws — this keystore cannot be written to, only read. */
public class SovKeyStoreSpi extends KeyStoreSpi {
    private String alias;
    private Certificate cert;

    @Override
    public void engineLoad(InputStream stream, char[] password) throws IOException {
        alias = System.getProperty("sov.alias", "sov");
        String certPath = System.getProperty("sov.cert");
        if (certPath == null) throw new IOException("system property sov.cert not set");
        try (FileInputStream fis = new FileInputStream(certPath)) {
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            cert = cf.generateCertificate(fis);
        } catch (Exception e) {
            throw new IOException("failed to load sov.cert", e);
        }
    }

    @Override public Key engineGetKey(String a, char[] password) {
        return alias.equals(a) ? new SovProxyPrivateKey(alias) : null;
    }
    @Override public Certificate[] engineGetCertificateChain(String a) {
        return alias.equals(a) ? new Certificate[]{cert} : null;
    }
    @Override public Certificate engineGetCertificate(String a) {
        return alias.equals(a) ? cert : null;
    }
    @Override public Date engineGetCreationDate(String a) { return new Date(); }
    @Override public Enumeration<String> engineAliases() {
        return Collections.enumeration(Collections.singletonList(alias));
    }
    @Override public boolean engineContainsAlias(String a) { return alias.equals(a); }
    @Override public int engineSize() { return 1; }
    @Override public boolean engineIsKeyEntry(String a) { return alias.equals(a); }
    @Override public boolean engineIsCertificateEntry(String a) { return false; }
    @Override public String engineGetCertificateAlias(Certificate c) { return null; }

    @Override public void engineSetKeyEntry(String a, Key k, char[] p, Certificate[] c) {
        throw new UnsupportedOperationException("read-only: keys come from the ceremony, not this store");
    }
    @Override public void engineSetKeyEntry(String a, byte[] k, Certificate[] c) {
        throw new UnsupportedOperationException("read-only");
    }
    @Override public void engineSetCertificateEntry(String a, Certificate c) {
        throw new UnsupportedOperationException("read-only");
    }
    @Override public void engineDeleteEntry(String a) {
        throw new UnsupportedOperationException("read-only");
    }
    @Override public void engineStore(OutputStream s, char[] p) {
        // no-op: nothing to persist, there is no secret material in this JVM to store
    }
}
