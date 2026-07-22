export const PROTOCOL_VERSION = "1.0" as const;
export const SCHEMA_VERSION = 1 as const;

export type ProtocolVersion = typeof PROTOCOL_VERSION;
export type SchemaVersion = typeof SCHEMA_VERSION;
