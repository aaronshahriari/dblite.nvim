package com.dblite.redis;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class RedisUrlTest {

    @Test
    void defaultsHostPortAndDatabase() {
        RedisUrl u = RedisUrl.parse("redis://localhost");
        assertEquals("localhost", u.host);
        assertEquals(6379, u.port);
        assertEquals(0, u.db);
        assertFalse(u.tls);
        assertNull(u.user);
        assertNull(u.password);
    }

    @Test
    void parsesPortAndDatabase() {
        RedisUrl u = RedisUrl.parse("redis://cache-01:6380/3");
        assertEquals("cache-01", u.host);
        assertEquals(6380, u.port);
        assertEquals(3, u.db);
    }

    @Test
    void parsesPasswordOnlyUserinfo() {
        RedisUrl u = RedisUrl.parse("redis://:secret@host:6379/1");
        assertNull(u.user);
        assertEquals("secret", u.password);
        assertEquals(1, u.db);
    }

    @Test
    void parsesAclUserAndPassword() {
        RedisUrl u = RedisUrl.parse("redis://alice:s3cr3t@host");
        assertEquals("alice", u.user);
        assertEquals("s3cr3t", u.password);
    }

    /** Passwords routinely contain characters that must be escaped in a URL. */
    @Test
    void percentDecodesUserinfo() {
        RedisUrl u = RedisUrl.parse("redis://:p%40ss%3Aword%2F1@host");
        assertEquals("p@ss:word/1", u.password);
    }

    /** A password containing '@' must not fool the authority split. */
    @Test
    void lastAtSeparatesUserinfoFromHost() {
        RedisUrl u = RedisUrl.parse("redis://user:a@b@realhost:6390");
        assertEquals("realhost", u.host);
        assertEquals(6390, u.port);
        assertEquals("a@b", u.password);
    }

    @Test
    void recognisesTlsScheme() {
        assertTrue(RedisUrl.parse("rediss://host:6380/0").tls);
        assertFalse(RedisUrl.parse("redis://host:6380/0").tls);
    }

    @Test
    void parsesBracketedIpv6Host() {
        RedisUrl u = RedisUrl.parse("redis://[::1]:6380/2");
        assertEquals("::1", u.host);
        assertEquals(6380, u.port);
        assertEquals(2, u.db);
    }

    @Test
    void ipv6WithoutPortKeepsDefault() {
        RedisUrl u = RedisUrl.parse("redis://[2001:db8::1]/1");
        assertEquals("2001:db8::1", u.host);
        assertEquals(6379, u.port);
    }

    @Test
    void acceptsDatabaseAsQueryParameter() {
        assertEquals(7, RedisUrl.parse("redis://host?db=7").db);
    }

    /** A '@' inside the query string must not be read as userinfo. */
    @Test
    void queryStringDoesNotDisturbAuthorityParsing() {
        RedisUrl u = RedisUrl.parse("redis://host:6379/2?db=5&tag=a@b");
        assertEquals("host", u.host);
        assertEquals(5, u.db);
        assertNull(u.password);
    }

    @Test
    void emptyHostFallsBackToLoopback() {
        assertEquals("127.0.0.1", RedisUrl.parse("redis://:6390").host);
    }

    @Test
    void rejectsBadInput() {
        assertThrows(IllegalArgumentException.class, () -> RedisUrl.parse("http://host"));
        assertThrows(IllegalArgumentException.class, () -> RedisUrl.parse("redis://host:0"));
        assertThrows(IllegalArgumentException.class, () -> RedisUrl.parse("redis://host:99999"));
        assertThrows(IllegalArgumentException.class, () -> RedisUrl.parse("redis://host:abc"));
        assertThrows(IllegalArgumentException.class, () -> RedisUrl.parse("redis://host/notanumber"));
        assertThrows(IllegalArgumentException.class, () -> RedisUrl.parse("redis://[::1"));
    }
}
