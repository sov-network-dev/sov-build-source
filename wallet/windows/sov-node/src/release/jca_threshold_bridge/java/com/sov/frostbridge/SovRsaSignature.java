package com.sov.frostbridge;

import java.io.*;
import java.security.*;
import java.security.spec.AlgorithmParameterSpec;
import java.util.Base64;

/** Registered as "Signature.SHA384withRSA" at high provider priority so apksigner's
 * ordinary sign call is transparently served by the threshold ceremony instead of
 * a local key file. Buffers the bytes apksigner feeds via engineUpdate (this IS the
 * real "signed data" apksigner computed per the APK v2/v3 spec — nothing here
 * reimplements that hashing/chunking logic, Google's own apksigner code already did
 * it correctly before calling us), then on engineSign() shells out to Node to run
 * the actual threshold-RSA ceremony and returns the resulting signature bytes. */
public abstract class SovRsaSignature extends SignatureSpi {
    private final ByteArrayOutputStream buf = new ByteArrayOutputStream();
    private String alias;
    protected abstract String ceremonyAlg(); // e.g. "RSA-SHA384" — the Node crypto.sign() name

    @Override protected void engineInitSign(PrivateKey privateKey) throws InvalidKeyException {
        if (!(privateKey instanceof SovProxyPrivateKey)) {
            throw new InvalidKeyException("expected SovProxyPrivateKey, got " + privateKey.getClass());
        }
        this.alias = ((SovProxyPrivateKey) privateKey).getAlias();
        buf.reset();
    }
    @Override protected void engineInitVerify(PublicKey publicKey) {
        throw new UnsupportedOperationException("verify not needed for this PoC — apksigner verify uses the real cert, not this provider");
    }
    @Override protected void engineUpdate(byte b) { buf.write(b); }
    @Override protected void engineUpdate(byte[] b, int off, int len) { buf.write(b, off, len); }

    @Override protected byte[] engineSign() throws SignatureException {
        try {
            File msgFile = File.createTempFile("sov-ceremony-msg-", ".bin");
            msgFile.deleteOnExit();
            try (FileOutputStream fos = new FileOutputStream(msgFile)) { fos.write(buf.toByteArray()); }

            String nodeExe = System.getProperty("sov.nodeExe", "node");
            String script = System.getProperty("sov.signScript");
            String threshold = System.getProperty("sov.threshold", "3");
            // Two ceremony shapes, selected by which config is present:
            //  - sov.holdersConfig set  -> network-distributed (ceremony_coordinator.js):
            //    shares fetched from separate share-holder services, none on this machine.
            //  - sov.sharesDir set      -> single-machine (ceremony_sign_cli.js), local files.
            // Same downstream contract either way: hex signature on stdout, nothing else.
            String holdersConfig = System.getProperty("sov.holdersConfig");
            java.util.List<String> cmd = new java.util.ArrayList<>(java.util.List.of(nodeExe, script));
            if (holdersConfig != null) {
                cmd.addAll(java.util.List.of("--holdersConfig", holdersConfig));
            } else {
                cmd.addAll(java.util.List.of("--sharesDir", System.getProperty("sov.sharesDir")));
            }
            cmd.addAll(java.util.List.of(
                "--threshold", threshold,
                "--alg", ceremonyAlg(),
                "--msgFile", msgFile.getAbsolutePath()
            ));
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.redirectErrorStream(false);
            Process p = pb.start();
            String stdout = new String(p.getInputStream().readAllBytes());
            String stderr = new String(p.getErrorStream().readAllBytes());
            int code = p.waitFor();
            msgFile.delete();
            if (code != 0) throw new SignatureException("ceremony CLI failed (exit " + code + "): " + stderr);

            String hex = stdout.trim();
            byte[] sig = new byte[hex.length() / 2];
            for (int i = 0; i < sig.length; i++) {
                sig[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
            }
            return sig;
        } catch (Exception e) {
            throw new SignatureException("threshold ceremony sign failed", e);
        }
    }

    @Override protected boolean engineVerify(byte[] sigBytes) {
        throw new UnsupportedOperationException("not used");
    }
    @Override protected void engineSetParameter(String param, Object value) {
        throw new UnsupportedOperationException("deprecated API not used");
    }
    @Override protected Object engineGetParameter(String param) {
        throw new UnsupportedOperationException("deprecated API not used");
    }
}
