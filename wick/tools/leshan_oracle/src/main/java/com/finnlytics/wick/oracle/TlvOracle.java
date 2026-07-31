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

import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.databind.JsonNode;

import org.eclipse.leshan.core.link.DefaultLinkParser;
import org.eclipse.leshan.core.link.LinkParseException;
import org.eclipse.leshan.core.model.ObjectModel;
import org.eclipse.leshan.core.model.ResourceModel;
import org.eclipse.leshan.core.model.ResourceModel.Operations;
import org.eclipse.leshan.core.model.ResourceModel.Type;
import org.eclipse.leshan.core.model.StaticModel;
import org.eclipse.leshan.core.node.LwM2mMultipleResource;
import org.eclipse.leshan.core.node.LwM2mNode;
import org.eclipse.leshan.core.node.LwM2mObject;
import org.eclipse.leshan.core.node.LwM2mObjectInstance;
import org.eclipse.leshan.core.node.LwM2mPath;
import org.eclipse.leshan.core.node.LwM2mResource;
import org.eclipse.leshan.core.node.LwM2mSingleResource;
import org.eclipse.leshan.core.node.ObjectLink;
import org.eclipse.leshan.core.node.codec.DefaultLwM2mEncoder;
import org.eclipse.leshan.core.request.ContentFormat;
import org.eclipse.leshan.core.util.Hex;

/**
 * Produces LwM2M TLV (Content-Format 11542) fixture bytes from JSON input specs, using
 * Eclipse Leshan's {@code DefaultLwM2mEncoder} as the reference implementation.
 *
 * <p>TLV needs two things SenML does not: the request path (the payload carries no names)
 * and an Object model (a TLV value is bare bytes, so nothing on the wire says whether four
 * of them are an Integer, a Float or a Time). The fixture therefore declares both, and the
 * Elixir side builds an equivalent {@code Wick.Object.Registry} from the same declarations
 * — so the two implementations are given identical inputs rather than each supplying its
 * own idea of the model.
 *
 * <pre>{@code
 * {
 *   "description": "device instance, LwM2M spec section 4.3.1",
 *   "path": "/3/0",
 *   "object_id": 3,
 *   "resources": [
 *     {"id": 0, "type": "STRING",  "value": "Open Mobile Alliance"},
 *     {"id": 9, "type": "INTEGER", "value": 87},
 *     {"id": 6, "type": "INTEGER", "instances": {"0": 1, "1": 5}}
 *   ]
 * }
 * }</pre>
 *
 * <p>{@code type} names a {@link ResourceModel.Type} constant. An {@code instances} object
 * makes the Resource multiple-instance; a {@code value} makes it single. {@code OPAQUE}
 * values are hex strings, {@code OBJLNK} values are {@code "object:instance"}.
 */
public final class TlvOracle {

    private TlvOracle() { /* no instances */ }

    /** Encode one fixture spec to TLV bytes. */
    public static byte[] encode(final JsonNode root) {
        int objectId = root.path("object_id").asInt();
        LwM2mPath path = new LwM2mPath(root.path("path").asText());

        List<ResourceModel> resourceModels = new ArrayList<>();
        List<LwM2mResource> resources = new ArrayList<>();

        for (JsonNode r : root.path("resources")) {
            int id = r.path("id").asInt();
            Type type = Type.valueOf(r.path("type").asText());
            boolean multiple = r.has("instances");

            resourceModels.add(new ResourceModel(id, "Resource " + id, Operations.RW, multiple,
                false, type, null, null, ""));
            resources.add(buildResource(id, type, multiple, r));
        }

        StaticModel model = new StaticModel(
            new ObjectModel(objectId, "Object " + objectId, "", ObjectModel.DEFAULT_VERSION,
                true, false, resourceModels));

        LwM2mNode node = buildNode(path, resources);

        return new DefaultLwM2mEncoder().encode(node, ContentFormat.TLV, null, path, model);
    }

    private static LwM2mNode buildNode(final LwM2mPath path, final List<LwM2mResource> resources) {
        if (path.isObject()) {
            return new LwM2mObject(path.getObjectId(), new LwM2mObjectInstance(0, resources));
        }
        if (path.isObjectInstance()) {
            return new LwM2mObjectInstance(path.getObjectInstanceId(), resources);
        }
        // A Resource or Resource Instance path targets exactly one Resource.
        return resources.get(0);
    }

    private static LwM2mResource buildResource(final int id, final Type type, final boolean multiple,
            final JsonNode r) {
        if (!multiple) {
            return LwM2mSingleResource.newResource(id, coerce(r.path("value"), type), type);
        }

        Map<Integer, Object> values = new HashMap<>();
        JsonNode instances = r.path("instances");
        instances.fieldNames().forEachRemaining(
            key -> values.put(Integer.parseInt(key), coerce(instances.path(key), type)));

        return LwM2mMultipleResource.newResource(id, values, type);
    }

    private static Object coerce(final JsonNode value, final Type type) {
        return switch (type) {
            case STRING -> value.asText();
            case CORELINK -> coreLink(value.asText());
            case INTEGER -> value.asLong();
            // Leshan models Time as a java.util.Date in milliseconds and divides by 1000 on
            // the way to the wire; Wick keeps epoch seconds throughout. Both emit the same
            // bytes, which is the whole point of comparing them.
            case TIME -> new Date(value.asLong() * 1000L);
            case UNSIGNED_INTEGER -> org.eclipse.leshan.core.util.datatype.ULong
                .valueOf(value.asLong());
            case FLOAT -> value.asDouble();
            case BOOLEAN -> value.asBoolean();
            case OPAQUE -> Hex.decodeHex(value.asText().toCharArray());
            case OBJLNK -> objectLink(value.asText());
            default -> throw new IllegalArgumentException("unsupported type: " + type);
        };
    }

    // Leshan types a CoRE Link Resource as a parsed Link[] and re-serializes it on the way
    // to the wire, so the fixture's text goes through a parse/serialize round trip before it
    // is compared. Wick stores the string as given. Anything the two disagree on here is a
    // CoRE Link Format normalisation difference, not a TLV one.
    private static Object coreLink(final String text) {
        try {
            return new DefaultLinkParser().parseCoreLinkFormat(text.getBytes());
        } catch (LinkParseException e) {
            throw new IllegalArgumentException("bad core link: " + text, e);
        }
    }

    private static ObjectLink objectLink(final String text) {
        String[] parts = text.split(":", 2);
        return new ObjectLink(Integer.parseInt(parts[0]), Integer.parseInt(parts[1]));
    }
}
