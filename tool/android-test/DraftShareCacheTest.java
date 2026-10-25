package com.example.safe_at_home;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;

public final class DraftShareCacheTest {
    private static final String FIRST = "draft-12345678-1234-4234-9234-123456789012.pdf";
    private static final String SECOND = "draft-87654321-4321-4321-a321-210987654321.pdf";

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("sah-share-cache-test-");
        try {
            File cache = root.resolve("cache").toFile();
            require(cache.mkdir(), "create cache");
            File folder = new File(cache, "share_plus");
            require(folder.mkdir(), "create plugin cache");
            Path first = Files.write(new File(folder, FIRST).toPath(), new byte[] {1});
            Path second = Files.write(new File(folder, SECOND).toPath(), new byte[] {2});
            Path unrelated = Files.write(new File(folder, "unrelated.pdf").toPath(), new byte[] {3});
            Path almost = Files.write(new File(folder, "draft-unknown.pdf").toPath(), new byte[] {4});
            Path nested = Files.createDirectory(new File(folder, "draft-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.pdf").toPath());
            require(DraftShareCache.clear(cache, FIRST) == 1, "exact completed share cleanup");
            require(!Files.exists(first) && Files.exists(second), "one share cannot delete another");
            require(DraftShareCache.clear(cache, FIRST) == 0, "repeat cleanup is safe");
            require(DraftShareCache.clear(cache, null) == 1, "startup/logout sweep removes owned drafts immediately");
            require(Files.exists(unrelated) && Files.exists(almost) && Files.exists(nested), "unrelated files/directories survive");
            try {
                DraftShareCache.clear(cache, "../" + FIRST);
                throw new AssertionError("path traversal accepted");
            } catch (IllegalArgumentException expected) { }
            Path outside = Files.write(root.resolve("outside.pdf"), new byte[] {5});
            Files.createSymbolicLink(first, outside);
            require(DraftShareCache.clear(cache, null) == 0, "file symlink rejected");
            require(Files.exists(outside) && Files.isSymbolicLink(first), "symlink and target preserved");
            Files.delete(first);
            Files.delete(unrelated);
            Files.delete(almost);
            Files.delete(nested);
            Files.delete(folder.toPath());
            Path outsideDirectory = Files.createDirectory(root.resolve("outside-directory"));
            Path outsideDraft = Files.write(outsideDirectory.resolve(FIRST), new byte[] {6});
            Files.createSymbolicLink(folder.toPath(), outsideDirectory);
            require(DraftShareCache.clear(cache, null) == 0 && Files.exists(outsideDraft), "directory symlink rejected");
            System.out.println("PASS: exact share, repeat, startup/logout, unrelated files, traversal, file/directory symlinks");
        } finally {
            try (var paths = Files.walk(root)) {
                for (Path path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }
}
