/*
 * Copyright 2026 Finnlytics
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */
package com.finnlytics.wick.oracle;

import java.io.File;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;

import org.eclipse.leshan.core.util.base64.DefaultBase64Decoder;
import org.eclipse.leshan.core.util.base64.DefaultBase64Decoder.DecoderAlphabet;
import org.eclipse.leshan.core.util.base64.DefaultBase64Decoder.DecoderPadding;
import org.eclipse.leshan.core.util.base64.DefaultBase64Encoder;
import org.eclipse.leshan.core.util.base64.DefaultBase64Encoder.EncoderAlphabet;
import org.eclipse.leshan.core.util.base64.DefaultBase64Encoder.EncoderPadding;
import org.eclipse.leshan.senml.SenMLPack;
import org.eclipse.leshan.senml.SenMLRecord;
import org.eclipse.leshan.senml.cbor.upokecenter.SenMLCborPackSerDes;
import org.eclipse.leshan.senml.json.jackson.SenMLJsonRecordSerDes;

/**
 * Produces SenML CBOR fixture bytes from JSON input specs, using Eclipse Leshan
 * 1.5.0's encoder as the reference implementation.
 *
 * <p>Each input file {@code foo.json} is read, encoded by Leshan, and written to
 * a sibling {@code foo.bin}. The Elixir test suite (Wick) loads both and asserts
 * byte-identical output from its own encoder.
 *
 * <p>The JSON shape mirrors {@code Wick.Senml.Record} field names verbatim:
 * <pre>{@code
 * {
 *   "description": "human-readable label",
 *   "allow_no_value": false,
 *   "records": [
 *     {
 *       "base_name":         "/3/0/",
 *       "base_time":         1700000000,
 *       "name":              "9",
 *       "time":              5,
 *       "number_value":      87,
 *       "string_value":      null,
 *       "boolean_value":     null,
 *       "opaque_value":      null,
 *       "object_link_value": null
 *     }
 *   ]
 * }
 * }</pre>
 *
 * <p>For {@code opaque_value}, the JSON string is interpreted as hex (case-insensitive,
 * no separators).
 *
 * <p>Numeric typing is preserved from JSON: integral JSON numbers become {@code Long},
 * fractional numbers become {@code Double}. {@code base_time} and {@code time} are
 * promoted to {@code BigDecimal} as Leshan requires.
 */
public final class Main {

    private Main() { /* no instances */ }

    public static void main(final String[] args) throws Exception {
        if (args.length != 2 || !Mode.isValid(args[0])) {
            System.err.println("usage: leshan-oracle <cbor|json> <fixtures-dir>");
            System.exit(2);
        }

        Mode mode = Mode.parse(args[0]);
        Path fixturesDir = Path.of(args[1]);
        if (!Files.isDirectory(fixturesDir)) {
            System.err.println("not a directory: " + fixturesDir);
            System.exit(2);
        }

        ObjectMapper mapper = new ObjectMapper()
            .enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);

        List<Path> jsonFiles;
        try (Stream<Path> stream = Files.list(fixturesDir)) {
            jsonFiles = new ArrayList<>(stream
                .filter(p -> p.getFileName().toString().endsWith(".json"))
                .sorted(Comparator.naturalOrder())
                .toList());
        }

        if (jsonFiles.isEmpty()) {
            System.err.println("no *.json fixtures found in " + fixturesDir);
            System.exit(0);
        }

        for (Path jsonFile : jsonFiles) {
            String stem = stripSuffix(jsonFile.getFileName().toString(), ".json");
            Path binFile = jsonFile.resolveSibling(stem + ".bin");

            JsonNode root = mapper.readTree(jsonFile.toFile());
            boolean allowNoValue = root.path("allow_no_value").asBoolean(false);

            SenMLPack pack = new SenMLPack();
            for (JsonNode r : root.path("records")) {
                pack.addRecord(buildRecord(r));
            }

            byte[] encoded = mode.encode(pack, allowNoValue, mapper);
            Files.write(binFile, encoded);

            System.out.printf(
                "%-44s -> %-44s (%4d bytes)%n",
                jsonFile.getFileName(), binFile.getFileName(), encoded.length);
        }

        System.out.println("OK: " + jsonFiles.size() + " " + mode + " fixture(s) regenerated.");
    }

    private enum Mode {
        CBOR, JSON;

        static boolean isValid(String name) {
            return "cbor".equals(name) || "json".equals(name);
        }

        static Mode parse(String name) {
            return "cbor".equals(name) ? CBOR : JSON;
        }

        byte[] encode(SenMLPack pack, boolean allowNoValue, ObjectMapper mapper) throws Exception {
            return switch (this) {
                case CBOR -> new SenMLCborPackSerDes(allowNoValue).serializeToCbor(pack);
                case JSON -> serializeJson(pack, allowNoValue, mapper);
            };
        }

        private static byte[] serializeJson(SenMLPack pack, boolean allowNoValue, ObjectMapper mapper)
                throws Exception {
            DefaultBase64Decoder decoder = new DefaultBase64Decoder(
                DecoderAlphabet.BASE64, DecoderPadding.REQUIRED);
            DefaultBase64Encoder encoder = new DefaultBase64Encoder(
                EncoderAlphabet.BASE64, EncoderPadding.WITH);
            SenMLJsonRecordSerDes serdes = new SenMLJsonRecordSerDes(allowNoValue, decoder, encoder);
            ArrayNode array = JsonNodeFactory.instance.arrayNode();
            for (SenMLRecord record : pack.getRecords()) {
                array.add(serdes.jSerialize(record));
            }
            return mapper.writeValueAsBytes(array);
        }

        @Override
        public String toString() {
            return name().toLowerCase();
        }
    }

    private static SenMLRecord buildRecord(final JsonNode r) {
        String baseName = textOrNull(r, "base_name");
        BigDecimal baseTime = bigDecimalOrNull(r, "base_time");
        String name = textOrNull(r, "name");
        BigDecimal time = bigDecimalOrNull(r, "time");

        Number numberValue = numberOrNull(r, "number_value");
        Boolean booleanValue = booleanOrNull(r, "boolean_value");
        String objectLinkValue = textOrNull(r, "object_link_value");
        String stringValue = textOrNull(r, "string_value");
        byte[] opaqueValue = opaqueOrNull(r, "opaque_value");

        return new SenMLRecord(
            baseName, baseTime,
            name, time,
            numberValue, booleanValue, objectLinkValue, stringValue, opaqueValue);
    }

    private static String textOrNull(final JsonNode r, final String key) {
        JsonNode n = r.get(key);
        return (n == null || n.isNull()) ? null : n.asText();
    }

    private static Boolean booleanOrNull(final JsonNode r, final String key) {
        JsonNode n = r.get(key);
        return (n == null || n.isNull()) ? null : n.asBoolean();
    }

    private static BigDecimal bigDecimalOrNull(final JsonNode r, final String key) {
        JsonNode n = r.get(key);
        if (n == null || n.isNull()) {
            return null;
        }
        if (n.isIntegralNumber()) {
            return BigDecimal.valueOf(n.longValue());
        }
        // USE_BIG_DECIMAL_FOR_FLOATS is enabled, so fractional numbers come as BigDecimal.
        return n.decimalValue();
    }

    /**
     * Mirror Elixir's {@code integer() | float()} polymorphism: integral JSON numbers
     * become Long, fractional numbers become Double. The CBOR encoder picks the
     * shortest wire representation regardless.
     */
    private static Number numberOrNull(final JsonNode r, final String key) {
        JsonNode n = r.get(key);
        if (n == null || n.isNull()) {
            return null;
        }
        if (n.isIntegralNumber()) {
            return n.longValue();
        }
        return n.doubleValue();
    }

    private static byte[] opaqueOrNull(final JsonNode r, final String key) {
        JsonNode n = r.get(key);
        if (n == null || n.isNull()) {
            return null;
        }
        return hexDecode(n.asText());
    }

    private static byte[] hexDecode(final String hex) {
        String s = hex.replaceAll("\\s+", "");
        if (s.length() % 2 != 0) {
            throw new IllegalArgumentException("hex string has odd length: " + hex);
        }
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < s.length(); i += 2) {
            int hi = Character.digit(s.charAt(i), 16);
            int lo = Character.digit(s.charAt(i + 1), 16);
            if (hi < 0 || lo < 0) {
                throw new IllegalArgumentException("invalid hex character in: " + hex);
            }
            out[i / 2] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    private static String stripSuffix(final String s, final String suffix) {
        return s.endsWith(suffix) ? s.substring(0, s.length() - suffix.length()) : s;
    }
}
