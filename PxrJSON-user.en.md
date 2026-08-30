# SJSON / BJSON — guide for database developers

English translation of [PxrJSON-user.ru.md](PxrJSON-user.ru.md).

This UDR is built on [JsonDataObjects](https://github.com/ahausladen/JsonDataObjects) (Andreas Hausladen) so the same JSON style (`Path`, `.S` / `.I` / `.L` / `.F` / `.B` / `.D`) is available inside Firebird. There is no minimum Firebird version beyond **3**.

Firebird has no JSON type. The packages cover two jobs: **parse** incoming JSON and pull fields, objects, and arrays into SQL / PSQL, and **build** JSON without spreading it across ordinary tables.

For speed and memory the UDR keeps a buffer per connection (attachment):

- a repeat call with the **same JSON text** does not parse again (last **64** distinct texts);
- `PARSE` stores the tree in a separate UDR buffer and returns a **key**. `CLONE` makes an independent copy and also returns a key. After that you can read and change JSON many times without parsing or serializing after every edit — pass the key instead of the text. To get text from a key, call `ToJSON`. The key lives until `Free(key)` or the Firebird session ends. Until then it can be used from any procedure, trigger, or function **of that same connection**.

Function names are the same in both packages. Always qualify: `SJSON.GET_S(...)`, `BJSON.PARSE(...)`.

The packages differ **only in the JSON document type** (string vs BLOB):

| Package | JSON in and out (`NEW_*`, `SET_*`, `GET`, `ToJSON`, …) | When to use |
|---------|--------------------------------------------------------|-------------|
| **SJSON** | `VARCHAR(8191) CHARACTER SET UTF8` | short JSON |
| **BJSON** | `BLOB SUB_TYPE TEXT CHARACTER SET UTF8` | large JSON |

Everything else matches: path is `VARCHAR`, `GET_S` is a string, `GET_I` is INTEGER, `PARSE` / `CLONE` return `CHAR(36)`, `Free` is BOOLEAN, and so on. A key from one package can be passed to the other.

Families are **`GET_*`**, **`SET_*`**, **`GET_AT_*`**, **`SET_AT_*`**, **`ADD_*`**, **`INS_*`**. The `*` is the type of the **JSON value**, not “SQL string vs BLOB”:

| Suffix | JSON type | Firebird type |
|--------|-----------|---------------|
| `_S` | string | `VARCHAR(8191)` |
| `_I` | integer | `INTEGER` |
| `_L` | long | `BIGINT` |
| `_F` | float | `DOUBLE PRECISION` |
| `_B` | boolean | `BOOLEAN` |
| `_D` | date-time | `TIMESTAMP` |

Without a suffix: `GET` / `SET_J` / `ADD_J` / `INS` — a node as JSON text (object, array, or scalar). `GET_B` is boolean, not BLOB. `ADD_A` / `INS_A` — empty array, `ADD_O` / `INS_O` — empty object (not “BLOB”).

---

## 1. JSON, key, path, and NULL

### 1.1. Argument `A_JSON`

Almost every function’s first parameter is `A_JSON`: the JSON you work with.

- In **SJSON** it is `VARCHAR(8191) UTF8` with text `{...}` or `[...]`.
- In **BJSON** it is `BLOB SUB_TYPE TEXT UTF8` with the same text, no 8191 limit.
- The JSON root must be an object or an array. A bare scalar (`10`, `"hi"`) as the whole document cannot be parsed.
- Invalid text → a Firebird exception, not SQL `NULL`.
- SQL `NULL` input: read/write functions return `NULL`; `NODES` / `ITEMS` return 0 rows.

Functions that **change** JSON (`SET_*`, `ADD_*`, `INS_*`, `REMOVE`, `CLEAR`, `ASSIGN`, `DELETEOF`, `SET_LEN`, …) return the same SQL type they accepted. If you passed JSON text, you get **new** JSON text. You must **assign** it, or the PSQL variable does not change:

```sql
j = SJSON.SET_S(j, 'address.city', 'Boston');
```

Pick the package that matches the type you already have: VARCHAR → `SJSON`, BLOB → `BJSON`. Mixing “SJSON with a BLOB, Firebird will coerce it” is not the intended use.

Below, **JSON** means that text (VARCHAR or BLOB depending on the package).

### 1.2. Key (`KEY`)

A key is not JSON. It is a handle to a tree already parsed in memory for the **current connection**.

| How you get it | What is cached |
|----------------|----------------|
| `PARSE(json)` | tree from the JSON text you passed |
| `CLONE(json)` | independent copy: from text or from an existing key — **always a new** key |
| `NEW_OBJKEY()` | empty object `{}` |
| `NEW_ARRKEY()` | empty array `[]` |

Key format: `CHAR(36) CHARACTER SET ASCII`, UUID **without** braces, pattern `8-4-4-4-12` (hex), e.g. `a1b2c3d4-e5f6-7890-abcd-ef1234567890`.

Rules:

- `PARSE` accepts **JSON text only**. A string that already looks like a key is an error.
- `CLONE` accepts JSON text or a key; the source document is unchanged; the result is another key.
- Unknown key in `GET_*` / `SET_*` → exception `JSON key not found`.
- A key from `SJSON.PARSE` can be passed to `BJSON.GET_*` and the other way around: the cache dictionaries are shared.
- While you work by key, `SET_*` mutates the tree **in place** and returns **the same** key. Text again comes from `ToJSON(key)`.
- The key lives until `Free(key)` or the Firebird session ends (client disconnect). Until then it can be used from **any** procedure, trigger, or function of this connection — not only the block that called `PARSE` / `CLONE`. Another connection does not see it.
- A second `Free` returns `FALSE`, not an exception. SQL `NULL` in `Free` → `NULL`.
- In `SET_J` / `ADD_J` / `INS` the third argument may also be a key: a **copy** of that tree is placed in the parent. `Free` of the copy does not destroy the original key.

`NEW_OBJECT()` / `NEW_ARRAY()` return JSON text `{}` / `[]` and **do not** create a key. For a long build in one connection, `NEW_OBJKEY` / `PARSE` / `CLONE` are more convenient.

**Everywhere a function takes JSON text** (first argument of `GET_*` / `SET_*` / `NODES` / `ITEMS` / `EXTRACTJSON` / `EXTRACTKEY` / `ToJSON` / `CLONE`, argument `json_value` / `source` of `SET_J` / `ADD_J` / `INS` / `ASSIGN`), **you may also pass a key**. The path (`A_PATH`) is always a path string, never a key. `CLONE` / `EXTRACTKEY` still return a **new** key, not text. `EXTRACTJSON` always returns JSON text of the cut node.

### 1.3. Path (`A_PATH`)

The second argument of most functions is the path to a node inside the JSON.

| Path | What it selects |
|------|-----------------|
| `''` (empty string) | the whole JSON (root) |
| `firstName` | a field in the root object |
| `address.city` | a field in a nested object |
| `phoneNumbers[0].number` | first array element, then a field |
| `[0].id` | the root itself is an array |

Field names are **case-sensitive**: `City` and `city` are different.

In a **path**, dots and brackets are navigation: `address.city` means “object `address`, field `city` inside”; `items[0]` is “element 0 of array `items`”.

Unlike a path, a **JSON object key name** must not contain dots or brackets. The function would treat that name as a path and look for nested objects: a literal key `a.b` or `x[0]` cannot be addressed by path.

`A_PATH` = SQL `NULL`: for `GET_*` / `SET_*` / `CLEAR` / `ASSIGN` / `INDEXOF` / `NAMEOF` / `EXTRACTJSON` / `EXTRACTKEY` the result is `NULL` / no write; for `NODES` / `ITEMS` NULL means root (same as `''`). Empty path `''` on `EXTRACTJSON` / `EXTRACTKEY` → exception (you cannot cut the root).

Reading by path **creates nothing**: missing node → SQL `NULL` / `EXIST` = `FALSE`.

Writing (`SET_*`, `ADD_*`, `INS_*`): if an intermediate object or array on the path **is missing**, it is created (empty, then the write continues). If the node **already exists**, it is left as-is, not recreated or cleared. You can build JSON from scratch (`SET_S('{}', 'user.address.city', 'NY')` creates `user` and `address`) and also extend an existing tree.

Array indexes are zero-based. Missing index: **read** behaves as “path not found” (SQL `NULL`, `EXIST` = `FALSE`); **write** → exception. Arrays are not stretched with holes: with 5 elements you cannot `SET` `[10]`. `ADD_*` always appends. `INS_*` inserts at `0` .. current `LEN` inclusive (insert at the end is allowed).

### 1.4. SQL NULL and JSON `null`

JSON has its own `null`. SQL has `NULL`. The packages distinguish them as follows:

| Situation | `GET_S` / `GET_I` / `GET_L` / `GET_F` / `GET_B` / `GET_D` | `GET` (node as JSON) | `EXIST` | `IS_NULL` |
|-----------|-----------------------------------------------|------------------------|---------|-----------|
| Path missing | SQL `NULL` | SQL `NULL` | `FALSE` | `FALSE` |
| JSON `null` at the path | SQL `NULL` | text `null` | `TRUE` | `TRUE` |
| Value present | the value | JSON text of the node | `TRUE` | `FALSE` |

An empty JSON string `""` is a value, not NULL: `GET_S` returns an empty VARCHAR.

Write: SQL `NULL` in the value of `SET_S` / `SET_I` / `SET_L` / `SET_F` / `SET_B` / `SET_D` / `SET_J` (and the same `SET_AT_*`) writes JSON `null` — same as `SET_NULL`. The key or document is still returned. SQL `NULL` in the JSON argument or in the path still yields SQL `NULL` (no write).

Scalars convert as in JsonDataObjects: `"10"` can be read with `GET_I` as `10`. An object or array cannot be converted to a typed get (`GET_S`, `GET_I`, …) — exception. An integer that does not fit in `INTEGER` also raises in `GET_I` (no silent truncation).

Missing path: `GET_TYPE`, `LEN`, `INDEXOF`, `NAMEOF` → SQL `NULL`. `LEN` on a scalar (not object or array) → SQL `NULL`.

---

## 2. Full list of UDR functions and procedures

Below are **all** functions and procedures of packages `SJSON` and `BJSON`. Names and meaning match; only the JSON type differs (VARCHAR or BLOB, see the package table at the start).

Wherever `json` is written, the first argument is JSON text **or a key** after `PARSE` / `CLONE` / `NEW_OBJKEY` / `NEW_ARRKEY` (§1.1–1.2). The second argument `path` is a path inside the JSON (§1.3). Empty path `''` is the root.

Column **Kind**:

- **Function** — returns one value. Use in `SELECT` and assignment: `v = SJSON.GET_S(j, 'name')`.
- **Command** — changes JSON or the key buffer. In SQL it is still a function: you **must assign** the result (`j = SJSON.SET_S(j, 'name', 'Ivan')`). Otherwise the PSQL variable does not change.
- **Procedure** — a set of rows: `select * from SJSON.NODES(j, '', true)`.

In the **Returns** column, **JSON** means VARCHAR in `SJSON` and BLOB in `BJSON`.

`PARSE` / `CLONE` / `Free`, extract `EXTRACTJSON` / `EXTRACTKEY`, and columns of `NODES` / `ITEMS` are described in §3–§6. Here is the full list and a short meaning of each.

### 2.1. Read

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `GET_S(json, path [, value_if_null])` | Function | `VARCHAR(8191)` | string (no JSON quotes) |
| `GET_I(json, path [, value_if_null])` | Function | `INTEGER` | integer |
| `GET_L(json, path [, value_if_null])` | Function | `BIGINT` | long integer |
| `GET_F(json, path [, value_if_null])` | Function | `DOUBLE PRECISION` | floating-point |
| `GET_B(json, path [, value_if_null])` | Function | `BOOLEAN` | boolean |
| `GET_D(json, path [, value_if_null])` | Function | `TIMESTAMP` | date-time (JDO `.D`) |
| `GET(json, path)` | Function | JSON | whole node as JSON text: object, array, or scalar (`"str"`, `10`, `true`, text `null`) |
| `GET_TYPE(json, path)` | Function | `VARCHAR(32)` | `null`, `String`, `Integer`, `Long`, `Float`, `Bool`, `Array`, `Object`, `DateTime` |
| `EXIST(json, path)` | Function | `BOOLEAN` | the path exists |
| `IS_NULL(json, path)` | Function | `BOOLEAN` | JSON `null` at the path (not “field missing”) |
| `LEN(json, path)` | Function | `INTEGER` | number of object keys or array elements |
| `INDEXOF(json, path)` | Function | `INTEGER` | index of the last path segment among siblings (object key or array index); missing → SQL `NULL` |
| `NAMEOF(json, path, index)` | Function | `VARCHAR(8191)` | name of the i-th object key at `path`; no object / out of range → SQL `NULL` |

Missing path → `GET_*` / `GET` / `GET_TYPE` / `LEN` SQL `NULL`; `EXIST` and `IS_NULL` → `FALSE`. JSON `null` at the path: typed `GET_S` / `GET_I` / … → SQL `NULL`, `GET` → text `null`, `EXIST` and `IS_NULL` → `TRUE`.

`GET_S` / `GET_I` / `GET_L` / `GET_F` / `GET_B` / `GET_D` (and the same `GET_AT_*`) have a third argument `value_if_null` defaulting to SQL `NULL`. If omitted, behaviour is as before. If passed — when the result would be SQL `NULL` (missing path, JSON `null`, NULL document) that value is returned, without `COALESCE` outside. Empty string `''` is not NULL; the substitute does not apply. `GET`, `GET_TYPE`, `LEN`, `INDEXOF`, `NAMEOF` do not have this argument.

### 2.2. Read array element (`GET_AT`)

`GET_AT` takes an element of **the array passed as the first argument**, by numeric index. These functions have no path parameter: the array **is** `json`.

Where the array comes from:

- the document is already an array (`[ ... ]`) — pass it as-is: `GET_AT(j, 0)` is the same as `GET(j, '[0]')` (empty path from the root, then only the index);
- the array sits inside an object — either a normal path: `GET_S(j, 'items[0].name')`, or fetch the array first and call `GET_AT` on it: `GET_AT(SJSON.GET(j, 'items'), 0)`.

If `json` is not an array, exception. Index from zero. Negative → exception. Too large on read → SQL `NULL` (as “element missing”).

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `GET_AT_S(json, index [, value_if_null])` | Function | `VARCHAR(8191)` | element as string |
| `GET_AT_I(json, index [, value_if_null])` | Function | `INTEGER` | integer |
| `GET_AT_L(json, index [, value_if_null])` | Function | `BIGINT` | long integer |
| `GET_AT_F(json, index [, value_if_null])` | Function | `DOUBLE PRECISION` | floating-point |
| `GET_AT_B(json, index [, value_if_null])` | Function | `BOOLEAN` | boolean |
| `GET_AT_D(json, index [, value_if_null])` | Function | `TIMESTAMP` | date-time |
| `GET_AT(json, index)` | Function | JSON | element as JSON (like `GET`) |
| `GET_AT_TYPE(json, index)` | Function | `VARCHAR(32)` | element type |

### 2.3. Write by path (`SET`)

Return JSON: new text if the input was text, or **the same key** if the input was a key. Missing objects on the path are created; existing ones are not touched. Array index out of range → exception (the array is not stretched with holes).

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `SET_S(json, path, value)` | Command | JSON | write a string; SQL `NULL` → JSON `null` |
| `SET_I(json, path, value)` | Command | JSON | write INTEGER; SQL `NULL` → JSON `null` |
| `SET_L(json, path, value)` | Command | JSON | write BIGINT; SQL `NULL` → JSON `null` |
| `SET_F(json, path, value)` | Command | JSON | write DOUBLE PRECISION; SQL `NULL` → JSON `null` |
| `SET_B(json, path, value)` | Command | JSON | write BOOLEAN; SQL `NULL` → JSON `null` |
| `SET_D(json, path, value)` | Command | JSON | write TIMESTAMP (JDO `.D`); SQL `NULL` → JSON `null` |
| `SET_NULL(json, path)` | Command | JSON | write JSON `null` |
| `SET_J(json, path, json_value)` | Command | JSON | put a node: object `{...}`, array `[...]`, or scalar (`"hi"`, `10`, `true`, `null`). `json_value` is JSON text or a key (tree is copied); SQL `NULL` → JSON `null` |

In **BJSON**, `SET_J`, `ADD_J`, and `INS` take `json_value` as BLOB (or a key). Scalar `SET_S` / `GET_S` are always `VARCHAR`, including in BJSON.

### 2.4. Write array element (`SET_AT`)

Like `GET_AT`: the first argument must be an array, the index is the element number. A nested array is specified the same way: either path `SET_S(j, 'items[0].name', ...)`, or `SET_AT` on JSON/key that already points at that array.

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `SET_AT_S(json, index, value)` | Command | JSON | write a string; SQL `NULL` → JSON `null` |
| `SET_AT_I(json, index, value)` | Command | JSON | write INTEGER; SQL `NULL` → JSON `null` |
| `SET_AT_L(json, index, value)` | Command | JSON | write BIGINT; SQL `NULL` → JSON `null` |
| `SET_AT_F(json, index, value)` | Command | JSON | write DOUBLE PRECISION; SQL `NULL` → JSON `null` |
| `SET_AT_B(json, index, value)` | Command | JSON | write BOOLEAN; SQL `NULL` → JSON `null` |
| `SET_AT_D(json, index, value)` | Command | JSON | write TIMESTAMP; SQL `NULL` → JSON `null` |
| `SET_AT_NULL(json, index)` | Command | JSON | JSON `null` in the cell |
| `SET_AT_J(json, index, json_value)` | Command | JSON | put a node in the cell |
| `REMOVE_AT(json, index)` | Command | JSON | delete the element at this index |

### 2.5. Append, insert, delete

`ADD_*` works **only with an array** at the path. If the array does not exist yet, it is created (and missing parents on the path if needed). If the array already exists, new elements are only appended **at the end**; existing ones are not changed.

`INS_*` inserts at `index` (`0` … current array length inclusive: you may insert at the end).

`CLEAR` / `ASSIGN` / `DELETEOF` / `SET_LEN` change an existing node: empty it, fill it, delete an object field by number, set array length. This is not `ADD_*`.

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `ADD_S(json, path, value)` | Command | JSON | append a string |
| `ADD_I(json, path, value)` | Command | JSON | append INTEGER |
| `ADD_L(json, path, value)` | Command | JSON | append BIGINT |
| `ADD_F(json, path, value)` | Command | JSON | append DOUBLE PRECISION |
| `ADD_B(json, path, value)` | Command | JSON | append BOOLEAN |
| `ADD_D(json, path, value)` | Command | JSON | append TIMESTAMP |
| `ADD_A(json, path)` | Command | JSON | append empty array `[]` |
| `ADD_O(json, path)` | Command | JSON | append empty object `{}` |
| `ADD_J(json, path, json_value)` | Command | JSON | append a node |
| `INS_S(json, path, index, value)` | Command | JSON | insert a string |
| `INS_I(json, path, index, value)` | Command | JSON | insert INTEGER |
| `INS_L(json, path, index, value)` | Command | JSON | insert BIGINT |
| `INS_F(json, path, index, value)` | Command | JSON | insert DOUBLE PRECISION |
| `INS_B(json, path, index, value)` | Command | JSON | insert BOOLEAN |
| `INS_D(json, path, index, value)` | Command | JSON | insert TIMESTAMP |
| `INS_A(json, path, index)` | Command | JSON | insert empty array `[]` |
| `INS_O(json, path, index)` | Command | JSON | insert empty object `{}` |
| `INS(json, path, index, json_value)` | Command | JSON | insert a node (JSON text or key) |
| `REMOVE(json, path)` | Command | JSON | delete an object field or array element by path |
| `EXTRACTJSON(json, path)` | Command | JSON text | cut the node, return it as JSON (like `GET`). Key input mutates the parent in place |
| `EXTRACTKEY(json, path)` | Command | `CHAR(36)` | cut an object/array, return a **new** key to that node. Scalar → exception |
| `CLEAR(json, path)` | Command | JSON | empty an object or array in place (`{}` / `[]`); `path = ''` — root; missing path / not object or array → exception |
| `ASSIGN(json, path, source)` | Command | JSON | copy contents of `source` (text or key) into the node at `path`; `path = ''` — root (types must match) |
| `DELETEOF(json, path, index)` | Command | JSON | delete the i-th field of an **object** (array — `REMOVE_AT`) |
| `SET_LEN(json, path, n)` | Command | JSON | set array `.Count` (`n >= 0`); object → exception |

### 2.6. Constructors and serialization

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `NEW_OBJECT()` | Function | JSON | empty object, text `{}` |
| `NEW_ARRAY()` | Function | JSON | empty array, text `[]` |
| `NEW_OBJKEY()` | Command | `CHAR(36)` | empty object in the key buffer |
| `NEW_ARRKEY()` | Command | `CHAR(36)` | empty array in the key buffer |
| `ToJSON(key [, compact])` | Function | JSON | serialize the tree by key (or JSON text). `compact` default `1` (one line); `0` — indented |
| `KeySize(json [, compact])` | Function | `INTEGER` | character length of the text `ToJSON` would return with the same `compact`. For a key — without sending the document to Firebird. In `SJSON` you can check whether it fits `VARCHAR(8191)` |

`NEW_OBJECT` / `NEW_ARRAY` do **not** create a key. For key-based work use `NEW_OBJKEY` / `NEW_ARRKEY`, `PARSE`, or `CLONE`.

### 2.7. Session key: `PARSE`, `CLONE`, and `Free`

Details in §3.

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `PARSE(json)` | Command | `CHAR(36)` | parse JSON text into the UDR buffer, return a key |
| `CLONE(json)` | Command | `CHAR(36)` | independent copy of the tree; **always a new key**, even if the input is already a key |
| `EXTRACTJSON(json, path)` | Command | JSON | cut a node, return JSON text |
| `EXTRACTKEY(json, path)` | Command | `CHAR(36)` | cut an object/array, return a new key |
| `Free(key)` | Command | `BOOLEAN` | drop the JSON — clear the UDR buffer for this key. Repeat → `FALSE`. SQL `NULL` → `NULL` |

### 2.8. Walk procedures

Column details in §4 and §5.

| Name | Kind | Returns | Meaning |
|------|------|---------|---------|
| `NODES(json, path [, full_path])` | Procedure | row set | depth-first walk starting at `path` |
| `ITEMS(json, path)` | Procedure | row set | one array level: a row per field of each element |

Call:

```sql
select * from SJSON.NODES(:j, 'address', true);
select * from SJSON.ITEMS(:j, 'phoneNumbers');
```

---

## 3. PARSE / CLONE / Free

`PARSE` puts JSON in a separate UDR buffer and returns a key. Then `GET_*` / `SET_*` are called with that key instead of text: no re-parse and no serialize after every edit.

`CLONE(json)` always returns a **new** key: from JSON text or from an existing key. The source document is unchanged. Free the copy like a `PARSE` key.

```sql
k = SJSON.PARSE('{"user":{"name":"Ivan"}}');
c = SJSON.CLONE(k);          -- another key, same content
c = SJSON.SET_I(c, 'user.id', 1);
-- k still has no id; c has id
```

Text from a key is only via `ToJSON(key)`. Character length of that text is `KeySize(key)` (same `compact`, default `1`): `CHAR_LENGTH(ToJSON(k))` without sending the whole JSON to Firebird. The key lives until `Free(key)` or the end of the Firebird session. Until destroyed it can be used from any procedure, trigger, or function **of this connection** (including `SJSON` and `BJSON`).

Typical cycle:

```sql
execute block returns (s varchar(8191))
as
  declare k char(36);
  declare ok boolean;
begin
  k = SJSON.PARSE('{"user":{"name":"Ivan"}}');
  k = SJSON.SET_I(k, 'user.id', 10);       -- same key
  s = SJSON.ToJSON(k);                     -- {"user":{"name":"Ivan","id":10}}
  ok = SJSON.Free(k);                      -- TRUE; a second Free is FALSE
  suspend;
end
```

---

## 4. NODES

The procedure walks JSON **depth-first**, starting at node `A_PATH` (empty string or SQL `NULL` — from the root). Each row is one node: object/array header first, then children.

```sql
select * from SJSON.NODES(:j, 'address', true);
```

| Parameter | Meaning |
|-----------|---------|
| `A_JSON` | JSON text or key |
| `A_PATH` | where to start; `NULL` = root |
| `A_FULL_PATH` | `TRUE` (default) — column `PATH` from the document root; `FALSE` — path only from the start node (first row has empty `PATH`) |

| Column | Meaning |
|--------|---------|
| `ABS_INDEX` | 0, 1, 2… **in this call** (the start node = 0), not “index in the whole file” |
| `LOC_INDEX` | for object/array — child count; for an object field — key index among siblings; for an array element — `n` |
| `NAME` | field name; for an array element `'[n]'`; for the JSON root — empty |
| `PATH` | see `A_FULL_PATH` |
| `TYP` | as `GET_TYPE` |
| `VAL` | scalar as `GET_S` (empty string is an empty field, not `""`); number / `true` / `false` as text; JSON `null` → **SQL NULL**; object/array — only markers `{}` / `[]`, not full content (children follow as later rows) |

Missing path or `A_JSON` SQL `NULL` → 0 rows, not an exception.

---

## 5. ITEMS

The procedure looks at **one array level**, without walking nested fields. If elements are objects, each key of each element is its own row. An array of objects becomes a table “row number + field name + value”.

```sql
select * from SJSON.ITEMS(:j, 'phoneNumbers');
```

| Column | Meaning |
|--------|---------|
| `LOC_INDEX` | array element index (0, 1, …) |
| `NAME` | field name inside the object; if the element is a scalar, array, or JSON `null` — `'[n]'` |
| `TYP` | as `GET_TYPE` |
| `VAL` | scalar as in `NODES` (JSON `null` → SQL NULL); nested object/array — **full** compact JSON (as `GET`), because the procedure does not descend |

Empty array, missing path, `A_JSON` SQL `NULL` → 0 rows. If the path is not an array (object, scalar, JSON `null`) → exception `ITEMS path is not an array`.

Firebird cannot do “as many SELECT columns as JSON keys”. Field names arrive in column `NAME`; a wide table is assembled by the client or PSQL when the schema is known (`GET_S`).

---

## 6. EXTRACTJSON / EXTRACTKEY

The functions cut the node at the path (like `REMOVE`) and return **the node**, not the parent. The root (`path = ''`) cannot be cut.

| Name | Returns | What is cut |
|------|---------|-------------|
| `EXTRACTJSON(json, path)` | JSON text (VARCHAR / BLOB) | any node, like `GET` |
| `EXTRACTKEY(json, path)` | `CHAR(36)` | object or array only; scalar / JSON `null` → exception |

If the input is a **key**, the node is removed from that tree in place; the same key then points at the parent without the node. If the input is **JSON text**, the caller’s string is unchanged (the cut uses a copy).

```sql
execute block
returns (extracted varchar(8191), k char(36), left_over varchar(8191))
as
  declare src char(36);
begin
  src = SJSON.PARSE('{"user":{"id":1,"addr":{"city":"NY"}}}');
  extracted = SJSON.EXTRACTJSON(src, 'user.id');   -- 1
  k = SJSON.EXTRACTKEY(src, 'user.addr');          -- new key to {"city":"NY"}
  left_over = SJSON.ToJSON(src);                   -- {"user":{}}
  suspend;
end
```

Missing path → SQL `NULL`. SQL `NULL` in `A_JSON` or `A_PATH` → SQL `NULL`. `REMOVE` deletes without returning the node; `CLEAR` leaves an empty object/array in place.

---

## 7. Mapping to Delphi JsonDataObjects (JDO)

Reads in the packages **do not create** missing nodes (in JDO, reading `Path` / `O[]` / `A[]` does). No field → SQL `NULL`, not `''` / `0` / `false`. On write, missing nodes on the path are created; existing ones stay.

| PxrJSON | JDO | Note |
|---------|-----|------|
| first argument (JSON text) | `Parse` / `ParseUtf8` / `FromJSON` | parse on the call |
| `PARSE` | — | tree in the session cache, UUID returned |
| `CLONE` | `Clone` | **always** a new key, from text or from a key |
| `Free` | — | PARSE/CLONE key only; repeat → `FALSE` |
| `ToJSON(key, compact)` | `ToJSON(Compact)` / `ToString` | `compact` 1 / 0 |
| `NEW_OBJECT()` | `TJsonObject.Create` | JSON `{}` |
| `NEW_ARRAY()` | `TJsonArray.Create` | JSON `[]` |
| `NEW_OBJKEY()` / `NEW_ARRKEY()` | — | empty object/array already in the cache |
| `GET_S` / `GET_I` / `GET_L` / `GET_F` / `GET_B` / `GET_D` | `.S` / `.I` / `.L` / `.F` / `.B` / `.D`, read `Path[]` | read does not create nodes |
| `SET_S` / `SET_I` / `SET_L` / `SET_F` / `SET_B` / `SET_D` | write `.S` / `.D` / `Path[]` | missing node on the path is created; existing is not recreated; SQL `NULL` in value → JSON `null` |
| `GET` | `.O` / `.A` / whole node | in SQL — JSON text, not a Delphi object |
| `SET_J` | write `.O` / `.A` / parse a literal into `Path` | JSON text or key (copy) |
| `SET_NULL` | `null` in a property (`O[name] := nil`) | |
| `GET_AT_*` / `SET_AT_*` | array `.S[i]` / `.I[i]` / `.D[i]` / … | first argument is an array; index `INTEGER` |
| `GET_TYPE` / `GET_AT_TYPE` | `Types[name]` / `Types[i]` | plus `'null'` for JSON `null`; for `.D` — `'DateTime'` |
| `LEN` | `.Count` | object and array; scalar → SQL `NULL` |
| `SET_LEN` | write `.Count` | array only; `n < 0` → exception |
| `INDEXOF` | `IndexOf(name)` / index of segment `[n]` | missing key → SQL `NULL` |
| `NAMEOF` | `Names[i]` | missing / out of range → SQL `NULL` |
| `EXIST(json, path)` | partly `Contains(name)` | JDO is one key, not path `a.b` |
| `IS_NULL` | `IsNull(name)` / `IsNull(i)` | in JDO often `True` when the key is missing; here only explicit JSON `null` |
| `ADD_*` / `ADD_J` / `ADD_A` / `ADD_O` | `Add(...)` / `AddArray` / `AddObject` | array only |
| `INS_*` / `INS` / `INS_A` / `INS_O` | `Insert(index, ...)` / `InsertArray` / `InsertObject` | index `0 .. Count` |
| `REMOVE` | `Remove(name)` | in PxrJSON — by path, not only a root key |
| `REMOVE_AT` | array `Delete(index)` | |
| `DELETEOF` | object `Delete(index)` | |
| `CLEAR` | `Clear` | object or array at the path |
| `ASSIGN` | `Assign` | `source` is JSON text or a key |
| `EXTRACTJSON` / `EXTRACTKEY` | `Extract` / `ExtractObject` / `ExtractArray` | return value is the cut node (text or a new key); parent is mutated on key input |
| `NODES` | — | tree walk as rows |
| `ITEMS` | — | one array level as a field table |

`.U` (UInt64) and `.DUtc` are not exported to SQL.

---

## 8. Examples

Package `SJSON`. For BLOB, switch to `BJSON` and the variable type to `BLOB SUB_TYPE TEXT CHARACTER SET UTF8`.

Calls below are PSQL: a variable, assignment from a function, `suspend`. The same style works in stored procedures.

### 8.1. Person (classic JSON example)

Source: [JSON, Wikipedia](https://en.wikipedia.org/wiki/JSON) / json.org style.

```json
{
  "firstName": "John",
  "lastName": "Smith",
  "isAlive": true,
  "age": 27,
  "address": {
    "streetAddress": "21 2nd Street",
    "city": "New York",
    "state": "NY",
    "postalCode": "10021-3100"
  },
  "phoneNumbers": [
    {"type": "home", "number": "212 555-1234"},
    {"type": "office", "number": "646 555-4567"}
  ],
  "children": [],
  "spouse": null
}
```

Reading fields:

```sql
execute block
returns (
  first_name varchar(8191),
  age integer,
  is_alive boolean,
  city varchar(8191),
  home_phone varchar(8191),
  spouse_type varchar(32),
  spouse_s varchar(8191),
  spouse_json varchar(8191),
  spouse_exist boolean,
  spouse_is_null boolean,
  has_middle boolean,
  phones integer,
  kids integer
)
as
  declare j varchar(8191);
begin
  j = '{
    "firstName": "John", "lastName": "Smith", "isAlive": true, "age": 27,
    "address": {"streetAddress": "21 2nd Street", "city": "New York", "state": "NY", "postalCode": "10021-3100"},
    "phoneNumbers": [{"type": "home", "number": "212 555-1234"}, {"type": "office", "number": "646 555-4567"}],
    "children": [], "spouse": null
  }';

  first_name = SJSON.GET_S(j, 'firstName');           -- John  (parse into the UDR buffer)
  age = SJSON.GET_I(j, 'age');                        -- 27
  is_alive = SJSON.GET_B(j, 'isAlive');               -- TRUE
  city = SJSON.GET_S(j, 'address.city');              -- New York
  home_phone = SJSON.GET_S(j, 'phoneNumbers[0].number');
  spouse_type = SJSON.GET_TYPE(j, 'spouse');          -- null
  spouse_s = SJSON.GET_S(j, 'spouse');                -- SQL NULL
  spouse_json = SJSON.GET(j, 'spouse');               -- text null
  spouse_exist = SJSON.EXIST(j, 'spouse');            -- TRUE
  spouse_is_null = SJSON.IS_NULL(j, 'spouse');        -- TRUE
  has_middle = SJSON.EXIST(j, 'middleName');          -- FALSE
  phones = SJSON.LEN(j, 'phoneNumbers');              -- 2
  kids = SJSON.LEN(j, 'children');                    -- 0
  suspend;
end
```

In this example the source JSON does not change. JSON is parsed inside the UDR once — on the first line; later calls take the tree from the buffer.

Change the city and append a phone — assign the `SET` / `ADD` result back to `j`:

```sql
execute block returns (j2 varchar(8191))
as
  declare j varchar(8191);
begin
  j = '{"firstName":"John","address":{"city":"New York"},"phoneNumbers":[{"type":"home","number":"212 555-1234"}]}';
  j = SJSON.SET_S(j, 'address.city', 'Boston');
  j = SJSON.ADD_J(j, 'phoneNumbers', '{"type":"mobile","number":"617 555-0000"}');
  j2 = SJSON.ToJSON(j);
  suspend;
end
```

Walk the address and the phones table (procedures still via `select`; inside a block — `for … in`):

```sql
execute block
returns (abs_index integer, loc_index integer, name varchar(8191), path varchar(8191), typ varchar(32), val varchar(8191))
as
  declare j varchar(8191);
begin
  j = '{"address":{"city":"New York","state":"NY"},"phoneNumbers":[{"type":"home","number":"212 555-1234"}]}';

  for select abs_index, loc_index, name, path, typ, val
      from SJSON.NODES(j, 'address', true)
      into :abs_index, :loc_index, :name, :path, :typ, :val
  do
    suspend;
end
```

```sql
execute block
returns (loc_index integer, name varchar(8191), typ varchar(32), val varchar(8191))
as
  declare j varchar(8191);
begin
  j = '{"phoneNumbers":[{"type":"home","number":"212 555-1234"},{"type":"office","number":"646 555-4567"}]}';

  for select loc_index, name, typ, val
      from SJSON.ITEMS(j, 'phoneNumbers')
      into :loc_index, :name, :typ, :val
  do
    suspend;
end
-- 0  type    String  home
-- 0  number  String  212 555-1234
-- 1  type    String  office
-- 1  number  String  646 555-4567
```

---

### 8.2. Menu (json.org example)

Source: [json.org/example.html](https://json.org/example.html), object `menu`.

```json
{
  "menu": {
    "id": "file",
    "value": "File",
    "popup": {
      "menuitem": [
        {"value": "New", "onclick": "CreateNewDoc()"},
        {"value": "Open", "onclick": "OpenDoc()"},
        {"value": "Close", "onclick": "CloseDoc()"}
      ]
    }
  }
}
```

```sql
execute block
returns (
  menu_id varchar(8191),
  menu_value varchar(8191),
  item_count integer,
  open_handler varchar(8191),
  j2 varchar(8191)
)
as
  declare j varchar(8191);
begin
  j = '{
    "menu": {
      "id": "file", "value": "File",
      "popup": {
        "menuitem": [
          {"value": "New", "onclick": "CreateNewDoc()"},
          {"value": "Open", "onclick": "OpenDoc()"},
          {"value": "Close", "onclick": "CloseDoc()"}
        ]
      }
    }
  }';

  menu_id = SJSON.GET_S(j, 'menu.id');                 -- file  (parse into the UDR buffer)
  menu_value = SJSON.GET_S(j, 'menu.value');           -- File
  item_count = SJSON.LEN(j, 'menu.popup.menuitem');    -- 3
  open_handler = SJSON.GET_S(j, 'menu.popup.menuitem[1].onclick'); -- OpenDoc()

  j = SJSON.INS(j, 'menu.popup.menuitem', 0,
                '{"value":"Save","onclick":"SaveDoc()"}');
  j2 = SJSON.ToJSON(j);
  suspend;
end
```

On read, the source JSON does not change. Parsing inside the UDR happens once — on the first line; later `GET_*` / `LEN` take the tree from the buffer. `INS` is already a write: `j` receives new JSON text.

Insert an empty array or object with `INS_A` / `INS_O` (no JSON literal). `CLEAR` empties a node in place:

```sql
j = SJSON.INS_O(j, 'menu.popup.menuitem', 0);   -- {} at the start of the list
j = SJSON.SET_S(j, 'menu.popup.menuitem[0].value', 'Save');
j = SJSON.CLEAR(j, 'menu.popup');               -- popup = {}
```

Menu items as a table:

```sql
execute block
returns (loc_index integer, name varchar(8191), val varchar(8191))
as
  declare j varchar(8191);
begin
  j = '{"menu":{"popup":{"menuitem":[{"value":"New"},{"value":"Open"},{"value":"Close"}]}}}';

  for select loc_index, name, val
      from SJSON.ITEMS(j, 'menu.popup.menuitem')
      where name = 'value'
      into :loc_index, :name, :val
  do
    suspend;
end
-- 0  value  New
-- 1  value  Open
-- 2  value  Close
```

---

### 8.3. Posts (array at the root, JSONPlaceholder style)

Source: [JSONPlaceholder](https://jsonplaceholder.typicode.com/posts).

```json
[
  {
    "userId": 1,
    "id": 1,
    "title": "sunt aut facere repellat provident occaecati excepturi optio reprehenderit",
    "body": "quia et suscipit\nsuscipit recusandae consequuntur expedita et cum"
  },
  {
    "userId": 1,
    "id": 2,
    "title": "qui est esse",
    "body": "est rerum tempore vitae\nsequi sint nihil reprehenderit dolor"
  }
]
```

The root of this example is an array. An element can be taken with path `'[n].…'` or `GET_AT` (the first argument is already an array):

```sql
execute block
returns (
  cnt integer,
  root_type varchar(32),
  first_id integer,
  second_id integer,
  first_post varchar(8191)
)
as
  declare j varchar(8191);
begin
  j = '[
    {"userId":1,"id":1,"title":"sunt aut facere","body":"quia et suscipit"},
    {"userId":1,"id":2,"title":"qui est esse","body":"est rerum tempore"}
  ]';

  cnt = SJSON.LEN(j, '');                 -- 2  (parse into the UDR buffer)
  root_type = SJSON.GET_TYPE(j, '');      -- Array
  first_id = SJSON.GET_I(j, '[0].id');    -- 1
  second_id = SJSON.GET_I(j, '[1].id');   -- 2
  first_post = SJSON.GET_AT(j, 0);        -- {"userId":1,"id":1,...}
  suspend;
end
```

The source JSON does not change. Parsing inside the UDR happens once — on the first line; later calls take the tree from the buffer.

Parse once, edit by key, return text:

```sql
execute block returns (title varchar(8191), j_out varchar(8191))
as
  declare j varchar(8191);
  declare k char(36);
  declare ok boolean;
begin
  j = '[{"userId":1,"id":1,"title":"old","body":"x"}]';
  k = SJSON.PARSE(j);
  k = SJSON.SET_S(k, '[0].title', 'hello');
  title = SJSON.GET_S(k, '[0].title');    -- hello
  j_out = SJSON.ToJSON(k);
  ok = SJSON.Free(k);
  suspend;
end
```

Build JSON from scratch (each `SET` returns JSON — write it back into the same variable):

```sql
execute block returns (post varchar(8191))
as
  declare j varchar(8191);
begin
  j = SJSON.NEW_OBJECT();
  j = SJSON.SET_I(j, 'userId', 1);
  j = SJSON.SET_I(j, 'id', 1);
  j = SJSON.SET_S(j, 'title', 'hello');
  post = SJSON.ToJSON(j);                 -- {"userId":1,"id":1,"title":"hello"}
  suspend;
end
```

The same via a key: between `SET` calls the text is not passed between Firebird and the UDR; it comes from the UDR once at the end via `ToJSON`.

```sql
execute block returns (post varchar(8191))
as
  declare k char(36);
  declare ok boolean;
begin
  k = SJSON.NEW_OBJKEY();
  k = SJSON.SET_I(k, 'userId', 1);
  k = SJSON.SET_I(k, 'id', 1);
  k = SJSON.SET_S(k, 'title', 'hello');
  post = SJSON.ToJSON(k);
  ok = SJSON.Free(k);
  suspend;
end
```

### 8.4. Repeated calls: without `PARSE` and with `PARSE`

Real measurement. JSON **63.8 Kb**, **10,000** repeated `BJSON.GET_S` of the same path.

Without `PARSE` every call sends the whole BLOB from Firebird to the UDR. With `PARSE` the loop only passes the key; the tree is already in the UDR buffer.

- Without `PARSE`: <span style="background-color:#ffc9c9;font-weight:700">Execute time = 4s 250ms</span>
- With `PARSE`: <span style="color:#1565c0;font-weight:700">Execute time = 218ms</span>

Example without `PARSE`:

```sql
execute block (a_json d_blob_text = :a_json)
returns (res_text d_str_8100)
as
declare variable p d_integer;
begin
  p = 0;
  while (p < 10000) do
  begin
    p = p + 1;
    res_text = bjson.get_s(a_json, 'uxevents[5].evt_sender_uuid');
  end

  suspend;
end
```

------ Performance info ------  
Prepare time = 0ms  
<span style="background-color:#ffc9c9;font-weight:700">Execute time = 4s 250ms</span>  
Avg fetch time = 4 250.00 ms  
Current memory = 10 642 348 816  
Max memory = 10 645 710 080  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 80 044  

Example with `PARSE`:

```sql
execute block (a_json d_blob_text = :a_json)
returns (res_text d_str_8100)
as
declare variable a_key d_str_100;
declare variable p d_integer;
begin
  a_key = bjson.parse(a_json);
  p = 0;
  while (p < 10000) do
  begin
    p = p + 1;
    res_text = bjson.get_s(a_key, 'uxevents[5].evt_sender_uuid');
  end

  bjson.free(a_key);
  suspend;
end
```

------ Performance info ------  
Prepare time = 16ms  
<span style="color:#1565c0;font-weight:700">Execute time = 218ms</span>  
Avg fetch time = 218.00 ms  
Current memory = 10 643 868 224  
Max memory = 10 646 153 712  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 52  

### 8.5. Same measurement with `SJSON` (“Person” JSON)

Real measurement. JSON from §8.1, package `SJSON` (`VARCHAR`), **100,000** repeated `GET_S`.

On short text the gain from `PARSE` is small: the UDR already remembers the last 64 distinct JSON strings, and `VARCHAR` between Firebird and the UDR is cheap.

- Without `PARSE`: <span style="background-color:#ffc9c9;font-weight:700">Execute time = 2s 313ms</span>
- With `PARSE`: <span style="color:#1565c0;font-weight:700">Execute time = 1s 938ms</span>

Example without `PARSE`:

```sql
execute block (a_json d_str_8100 = :a_json)
returns (res_text d_str_8100)
as
declare variable p d_integer;
begin
  p = 0;
  while (p < 100000) do
  begin
    p = p + 1;
    res_text = sjson.get_s(a_json, 'phoneNumbers[1].number');
  end

  suspend;
end
```

------ Performance info ------  
Prepare time = 0ms  
<span style="background-color:#ffc9c9;font-weight:700">Execute time = 2s 313ms</span>  
Avg fetch time = 2 313.00 ms  
Current memory = 10 642 373 040  
Max memory = 10 646 163 504  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 32  

Example with `PARSE`:

```sql
execute block (a_json d_str_8100 = :a_json)
returns (res_text d_str_8100)
as
declare variable a_key d_str_100;
declare variable p d_integer;
begin
  a_key = sjson.parse(a_json);
  p = 0;
  while (p < 100000) do
  begin
    p = p + 1;
    res_text = sjson.get_s(a_key, 'phoneNumbers[1].number');
  end

  sjson.free(a_key);
  suspend;
end
```

------ Performance info ------  
Prepare time = 0ms  
<span style="color:#1565c0;font-weight:700">Execute time = 1s 938ms</span>  
Avg fetch time = 1 938.00 ms  
Current memory = 10 642 494 384  
Max memory = 10 646 163 504  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 40  

**Summary**

<table>
  <tr>
    <th></th>
    <th>§8.4 <code>BJSON</code>, 63.8 Kb, 10,000 calls</th>
    <th>§8.5 <code>SJSON</code>, “Person”, 100,000 calls</th>
  </tr>
  <tr>
    <td>Without <code>PARSE</code></td>
    <td><span style="background-color:#ffc9c9;font-weight:700">Execute time = 4s 250ms</span>, Fetches = 80 044</td>
    <td><span style="background-color:#ffc9c9;font-weight:700">Execute time = 2s 313ms</span>, Fetches = 32</td>
  </tr>
  <tr>
    <td>With <code>PARSE</code></td>
    <td><span style="color:#1565c0;font-weight:700">Execute time = 218ms</span>, Fetches = 52</td>
    <td><span style="color:#1565c0;font-weight:700">Execute time = 1s 938ms</span>, Fetches = 40</td>
  </tr>
</table>

Why `PARSE` barely helps on short `VARCHAR`:

- the UDR already remembers the last **64** distinct JSON texts — a repeat `GET_S` with the same `a_json` does not parse again;
- passing `VARCHAR` between Firebird and the UDR is cheap, unlike BLOB (BLOB pages, 80 044 fetches vs 32).

`PARSE` pays off when JSON is **large** (as in §8.4) or you **edit** it with `SET_*`: between edits the text is not shuttled back and forth; Firebird gets it once via `ToJSON`.
