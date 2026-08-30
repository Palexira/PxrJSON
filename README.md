# PxrJSON

Firebird UDR for working with JSON in SQL and PSQL. There is no JSON type in Firebird; this plugin adds two packages with the same API:

| Package | JSON document | Typical use |
|---------|----------------|-------------|
| **SJSON** | `VARCHAR(8191) CHARACTER SET UTF8` | small JSON, no BLOB round-trip |
| **BJSON** | `BLOB SUB_TYPE TEXT CHARACTER SET UTF8` | large JSON |

Read and write values by path (`user.address.city`, `items[0].id`), build documents without parking intermediate text in regular tables, and walk trees as result sets (`NODES` / `ITEMS`).

The parser is [JsonDataObjects](https://github.com/ahausladen/JsonDataObjects) (Andreas Hausladen). Path style matches JDO (`Path`, `.S` / `.I` / `.L` / `.F` / `.B` / `.D`). Firebird **3** and newer; bitness of the plugin must match the server (x64).

## Features

- Typed getters and setters: `GET_S`, `GET_I`, `GET_L`, `GET_F`, `GET_B`, `GET_D`, `SET_*`, plus `GET` / `SET_J` for a whole node as JSON text
- Arrays: `GET_AT_*` / `SET_AT_*`, `ADD_*`, `INS_*`, `REMOVE` / `REMOVE_AT`
- Session cache: `PARSE` returns a `CHAR(36)` key; further calls use the key instead of resending the document. `CLONE`, `Free`, `ToJSON`, `KeySize`
- Hash LRU of the last **64** distinct JSON texts per attachment (repeat `GET_*` on the same VARCHAR/BLOB string does not re-parse)
- `EXTRACTJSON` / `EXTRACTKEY` — cut a node and return it as text or a new key
- Selectable procedures `NODES` (DFS) and `ITEMS` (one array level as a table)
- Win64 (`PxrJSON.dll`) and Linux64 (`libPxrJSON.so`)

Call names are always qualified: `SJSON.GET_S(...)`, `BJSON.PARSE(...)`. A key from one package works in the other.

## Install

1. Copy the plugin into `Firebird/plugins/udr/` (`PxrJSON.dll` or `libPxrJSON.so`).
2. Run [`PxrJSON.sql`](PxrJSON.sql) on the database (`CREATE OR ALTER PACKAGE` for `SJSON` and `BJSON`).
3. After a DLL rebuild, run the SQL script again.

`EXTERNAL NAME` is the same on both OS, for example `'PxrJSON!SJson_GetL'`.

## Quick example

```sql
execute block
returns (city varchar(8191), j varchar(8191))
as
  declare k char(36);
  declare ok boolean;
begin
  k = SJSON.PARSE('{"user":{"name":"Ivan"}}');
  k = SJSON.SET_S(k, 'user.address.city', 'Boston');
  city = SJSON.GET_S(k, 'user.address.city');
  j = SJSON.ToJSON(k);
  ok = SJSON.Free(k);
  suspend;
end
```

Use **BJSON** the same way when the document is a BLOB. For a large document that you read or update many times, `PARSE` once and pass the key — sending the whole BLOB on every `GET_S` is much slower.

## Documentation

| File | Language | Contents |
|------|----------|----------|
| [PxrJSON-user.en.md](PxrJSON-user.en.md) | English | User manual for database developers |
| [PxrJSON-user.ru.md](PxrJSON-user.ru.md) | Russian | Same manual |
| [PxrJSON.sql](PxrJSON.sql) | SQL | Package declarations and `COMMENT ON` |

## Build

Delphi project: [`PxrJSON.dpr`](PxrJSON.dpr) / [`PxrJSON.dproj`](PxrJSON.dproj). Output: **Win64** `PxrJSON.dll`, **Linux64** `libPxrJSON.so`.

## Credits

JSON parsing and the in-memory tree are [JsonDataObjects](https://github.com/ahausladen/JsonDataObjects) by Andreas Hausladen. Firebird API bindings are the OO `Firebird.pas` UDR headers (no link to `fbclient`).
