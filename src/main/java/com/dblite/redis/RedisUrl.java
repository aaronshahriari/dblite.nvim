package com.dblite.redis;

import java.nio.charset.StandardCharsets;

/**
 * Parses redis:// and rediss:// URLs.
 *
 *   redis://[[user][:password]@]host[:port][/db][?db=N]
 *
 * Userinfo is percent-decoded, since Redis passwords routinely contain
 * characters that have to be escaped to survive a URL.
 */
public final class RedisUrl {
    public final String  host;
    public final int     port;
    public final int     db;
    public final String  user;
    public final String  password;
    public final boolean tls;

    private RedisUrl(String host, int port, int db, String user, String password, boolean tls) {
        this.host = host;
        this.port = port;
        this.db = db;
        this.user = user;
        this.password = password;
        this.tls = tls;
    }

    public static RedisUrl parse(String url) {
        String lower = url.toLowerCase(java.util.Locale.ROOT);
        boolean tls;
        String rest;
        if (lower.startsWith("rediss://")) {
            tls = true;
            rest = url.substring("rediss://".length());
        } else if (lower.startsWith("redis://")) {
            tls = false;
            rest = url.substring("redis://".length());
        } else {
            throw new IllegalArgumentException("Not a Redis URL: " + url);
        }

        // Split off the query string first so a '@' or '/' inside it cannot
        // confuse the authority parsing below.
        String query = null;
        int q = rest.indexOf('?');
        if (q >= 0) {
            query = rest.substring(q + 1);
            rest  = rest.substring(0, q);
        }

        String user = null;
        String password = null;
        int at = rest.lastIndexOf('@');
        if (at >= 0) {
            String userinfo = rest.substring(0, at);
            rest = rest.substring(at + 1);
            int colon = userinfo.indexOf(':');
            if (colon >= 0) {
                user     = decode(userinfo.substring(0, colon));
                password = decode(userinfo.substring(colon + 1));
            } else {
                user = decode(userinfo);
            }
            if (user != null && user.isEmpty()) user = null;
            if (password != null && password.isEmpty()) password = null;
        }

        int db = 0;
        int slash = rest.indexOf('/');
        if (slash >= 0) {
            String dbPart = rest.substring(slash + 1).trim();
            rest = rest.substring(0, slash);
            if (!dbPart.isEmpty()) {
                try {
                    db = Integer.parseInt(dbPart);
                } catch (NumberFormatException e) {
                    throw new IllegalArgumentException("Invalid Redis database index: " + dbPart);
                }
            }
        }

        if (query != null) {
            for (String pair : query.split("&")) {
                int eq = pair.indexOf('=');
                if (eq < 0) continue;
                String k = pair.substring(0, eq);
                String v = decode(pair.substring(eq + 1));
                if ("db".equalsIgnoreCase(k) && !v.isEmpty()) {
                    try {
                        db = Integer.parseInt(v.trim());
                    } catch (NumberFormatException e) {
                        throw new IllegalArgumentException("Invalid Redis database index: " + v);
                    }
                }
            }
        }

        String host = rest;
        int port = 6379;
        if (host.startsWith("[")) {                 // bracketed IPv6 literal
            int close = host.indexOf(']');
            if (close < 0) throw new IllegalArgumentException("Unterminated IPv6 host in: " + url);
            String bracketed = host.substring(1, close);
            String after = host.substring(close + 1);
            if (after.startsWith(":")) port = parsePort(after.substring(1));
            host = bracketed;
        } else {
            int colon = host.lastIndexOf(':');
            if (colon >= 0) {
                port = parsePort(host.substring(colon + 1));
                host = host.substring(0, colon);
            }
        }

        if (host.isEmpty()) host = "127.0.0.1";
        if (db < 0) throw new IllegalArgumentException("Redis database index cannot be negative");

        return new RedisUrl(host, port, db, user, password, tls);
    }

    private static int parsePort(String s) {
        try {
            int p = Integer.parseInt(s.trim());
            if (p < 1 || p > 65535) throw new NumberFormatException(s);
            return p;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Invalid Redis port: " + s);
        }
    }

    private static String decode(String s) {
        if (s.indexOf('%') < 0 && s.indexOf('+') < 0) return s;
        return java.net.URLDecoder.decode(s, StandardCharsets.UTF_8);
    }

    @Override
    public String toString() {
        return (tls ? "rediss://" : "redis://") + host + ":" + port + "/" + db;
    }
}
