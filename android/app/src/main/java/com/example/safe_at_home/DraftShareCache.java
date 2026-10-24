package com.example.safe_at_home;

import java.io.File;
import java.io.IOException;
import java.util.regex.Pattern;

public final class DraftShareCache {
    private static final Pattern OWNED_NAME = Pattern.compile(
            "draft-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.pdf");

    private DraftShareCache() {}

    public static int clear(File cacheRoot, String name) throws IOException {
        if (name != null && !OWNED_NAME.matcher(name).matches()) {
            throw new IllegalArgumentException("Invalid draft share name");
        }
        File folder = new File(cacheRoot.getCanonicalFile(), "share_plus");
        if (!folder.getAbsoluteFile().equals(folder.getCanonicalFile()) || !folder.isDirectory()) {
            return 0;
        }
        File[] entries = folder.listFiles();
        if (entries == null) throw new IOException("Draft share cache unavailable");
        int deleted = 0;
        for (File entry : entries) {
            if (!OWNED_NAME.matcher(entry.getName()).matches()
                    || (name != null && !name.equals(entry.getName()))
                    || !entry.isFile()
                    || !entry.getAbsoluteFile().equals(entry.getCanonicalFile())
                    || !folder.equals(entry.getCanonicalFile().getParentFile())) continue;
            if (!entry.delete() && entry.exists()) throw new IOException("Draft share cleanup failed");
            deleted++;
        }
        return deleted;
    }
}
