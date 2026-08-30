# SJSON / BJSON — справочник для разработчика БД

Данный UDR написан на базе библиотеки [JsonDataObjects](https://github.com/ahausladen/JsonDataObjects) (Andreas Hausladen), чтобы тот же стиль работы с JSON (`Path`, `.S` / `.I` / `.L` / `.F` / `.B` / `.D`) был доступен в СУБД Firebird. Ограничения по версии сервера у UDR нет: пакеты работают в Firebird 3 и новее.

В Firebird нет типа JSON. Пакеты закрывают два сценария: **разобрать** входящий JSON и вытащить поля, объекты и массивы в SQL / PSQL, и **собрать** JSON, не раскладывая его по обычным таблицам.

Для ускорения и экономии памяти внутри UDR есть буфер на каждое соединение (attachment):

- повторный вызов с **тем же JSON-текстом** не разбирает строку заново (хранятся последние 64 различных текста);
- `PARSE` кладёт JSON в отдельный буфер UDR и возвращает **ключ** для дальнейшего обращения к нему. `CLONE` делает независимую копию дерева и тоже возвращает ключ. Дальше можно много раз читать и менять JSON без повторного разбора и без сериализации после каждой правки — достаточно вызывать функции, передавая ключ вместо JSON-текста. Чтобы получить текст по ключу, нужно вызвать `ToJSON`. Ключ живёт до явного `Free(ключ)` или до завершения сессии Firebird. Пока ключ не уничтожен, по нему можно обращаться из любой процедуры, триггера или функции **этого же подключения**.

Имена функций в обоих пакетах одинаковые. Вызов всегда с квалификатором: `SJSON.GET_S(...)`, `BJSON.PARSE(...)`.

Пакеты отличаются **только типом самого JSON** (строка или BLOB):

| Пакет | JSON на входе и на выходе (`NEW_*`, `SET_*`, `GET`, `ToJSON`, …) | Когда брать |
|-------|----------------------------------------------------------------|-------------|
| **SJSON** | `VARCHAR(8191) CHARACTER SET UTF8` | короткий JSON |
| **BJSON** | `BLOB SUB_TYPE TEXT CHARACTER SET UTF8` | большой JSON |

Всё остальное в `SJSON` и `BJSON` совпадает: путь — `VARCHAR`, `GET_S` — строка, `GET_I` — INTEGER, `PARSE` / `CLONE` — ключ `CHAR(36)`, `Free` — BOOLEAN, и так далее. Ключ, полученный в одном пакете, можно передать в другой.

Речь идёт о семействах **`GET_*`**, **`SET_*`**, **`GET_AT_*`**, **`SET_AT_*`**, а также **`ADD_*`** и **`INS_*`**. Вместо `*` подставляется суффикс типа **значения внутри JSON**, не «строка SQL vs BLOB»:

| Суффикс | Тип в JSON | Тип в Firebird |
|---------|------------|----------------|
| `_S` | string | `VARCHAR(8191)` |
| `_I` | integer | `INTEGER` |
| `_L` | long | `BIGINT` |
| `_F` | float | `DOUBLE PRECISION` |
| `_B` | boolean | `BOOLEAN` |
| `_D` | date-time | `TIMESTAMP` |

Без суффикса: `GET` / `SET_J` / `ADD_J` / `INS` — узел как JSON-текст (объект, массив или скаляр). `GET_B` — это boolean, не BLOB. `ADD_A` / `INS_A` — пустой массив, `ADD_O` / `INS_O` — пустой объект (не «BLOB»).

---

## 1. JSON, ключ, путь и NULL

### 1.1. Аргумент `A_JSON`

Почти у всех функций первый параметр — `A_JSON`: тот JSON, с которым вы работаете.

- В **SJSON** это строка `VARCHAR(8191) UTF8` с текстом `{...}` или `[...]`.
- В **BJSON** это `BLOB SUB_TYPE TEXT UTF8` с тем же текстом, только без лимита 8191.
- Корень JSON должен быть объектом или массивом. Голый скаляр (`10`, `"hi"`) как весь документ разобрать нельзя.
- Некорректный текст → исключение Firebird, не SQL `NULL`.
- Если передать SQL `NULL`: функции чтения/записи возвращают `NULL`, процедуры `NODES` / `ITEMS` — 0 строк.

Функции, которые **меняют** JSON (`SET_*`, `ADD_*`, `INS_*`, `REMOVE`, `CLEAR`, `ASSIGN`, `DELETEOF`, `SET_LEN`, …), возвращают результат того же SQL-типа, что приняли. Если на вход дали JSON-текст, на выход придёт **новый** JSON-текст. Его нужно **присвоить** переменной, иначе в PSQL ничего не изменится:

```sql
j = SJSON.SET_S(j, 'address.city', 'Boston');
```

Пакет берите по тому типу, который у вас уже есть: VARCHAR → `SJSON`, BLOB → `BJSON`. Смешивать «SJSON с BLOB, Firebird сам приведёт» — не целевой сценарий.

Ниже по тексту **JSON** означает этот текст (VARCHAR или BLOB в зависимости от пакета).

### 1.2. Ключ (`KEY`)

Ключ — это не JSON, а ссылка на уже разобранное дерево в памяти **текущего соединения**.

| Как получить | Что лежит в кэше |
|--------------|------------------|
| `PARSE(json)` | дерево из переданного JSON-текста |
| `CLONE(json)` | независимая копия: с текста или с уже существующего ключа — **всегда новый** ключ |
| `NEW_OBJKEY()` | пустой объект `{}` |
| `NEW_ARRKEY()` | пустой массив `[]` |

Формат ключа: `CHAR(36) CHARACTER SET ASCII`, UUID **без** фигурных скобок, шаблон `8-4-4-4-12` (шестнадцатеричные цифры), например `a1b2c3d4-e5f6-7890-abcd-ef1234567890`.

Правила:

- `PARSE` принимает **только JSON-текст**. Строка, которая уже выглядит как ключ, — ошибка.
- `CLONE` принимает и JSON-текст, и ключ; исходный документ не меняется, возврат — другой ключ.
- Неизвестный ключ в `GET_*` / `SET_*` — исключение `JSON key not found`.
- Ключ из `SJSON.PARSE` можно передать в `BJSON.GET_*` и наоборот: словари кэша общие.
- Пока вы работаете по ключу, `SET_*` меняет дерево **на месте** и возвращает **тот же** ключ. Текст снова получают через `ToJSON(ключ)`.
- Ключ живёт до явного `Free(ключ)` или до завершения сессии Firebird (отключение клиента). Пока ключ не уничтожен, им можно пользоваться из **любой** процедуры, триггера или функции этого подключения — не только из того блока, где вызвали `PARSE` / `CLONE`. Другое подключение этот ключ не видит.
- Повторный `Free` возвращает `FALSE`, не исключение. SQL `NULL` в `Free` → `NULL`.
- В `SET_J` / `ADD_J` / `INS` третьим аргументом тоже можно передать ключ: в родителя кладётся **копия** того дерева. `Free` копии исходный ключ не уничтожает.

`NEW_OBJECT()` / `NEW_ARRAY()` возвращают JSON-текст `{}` / `[]` и **не** создают ключ. Для длинной клейки в одном соединении удобнее `NEW_OBJKEY` / `PARSE` / `CLONE`.

**Везде, где функция принимает JSON-текст** (первый аргумент `GET_*` / `SET_*` / `NODES` / `ITEMS` / `EXTRACTJSON` / `EXTRACTKEY` / `ToJSON` / `CLONE`, аргумент `json_value` / `source` у `SET_J` / `ADD_J` / `INS` / `ASSIGN`), **можно также передавать ключ вместо JSON**. Путь (`A_PATH`) — всегда строка пути, не ключ. `CLONE` / `EXTRACTKEY` при этом всё равно вернут **новый** ключ, не текст. `EXTRACTJSON` всегда вернёт JSON-текст вырезанного узла.

### 1.3. Путь (`A_PATH`)

Второй аргумент у большинства функций — путь к узлу внутри JSON.

| Путь | Что выбирает |
|------|----------------|
| `''` (пустая строка) | весь JSON (корень) |
| `firstName` | поле в корневом объекте |
| `address.city` | поле во вложенном объекте |
| `phoneNumbers[0].number` | нулевой элемент массива, затем поле |
| `[0].id` | корень сам является массивом |

Имена полей **чувствительны к регистру**: `City` и `city` — разные поля.

В **пути** точка и скобки — это навигация: `address.city` значит «объект `address`, внутри него поле `city`»; `items[0]` — «нулевой элемент массива `items`».

В отличие от пути, в **названии ключа** нельзя использовать точку и скобки. Иначе функция поймёт это имя как путь и начнёт искать вложенные объекты: ключ буквально `a.b` или `x[0]` задать через путь нельзя.

`A_PATH` = SQL `NULL`: у `GET_*` / `SET_*` / `CLEAR` / `ASSIGN` / `INDEXOF` / `NAMEOF` / `EXTRACTJSON` / `EXTRACTKEY` результат `NULL` / запись не выполняется; у `NODES` / `ITEMS` NULL означает корень (как `''`). Пустой путь `''` у `EXTRACTJSON` / `EXTRACTKEY` — исключение (корень вырезать нельзя).

Чтение по пути **ничего не создаёт**: нет узла — SQL `NULL` / `EXIST` = `FALSE`.

Запись (`SET_*`, `ADD_*`, `INS_*`): если на пути **нет** промежуточного объекта или массива — он создаётся (пустой, затем запись идёт дальше). Если узел **уже есть** — он остаётся как есть, заново не создаётся и не очищается. Так можно собрать JSON с нуля (`SET_S('{}', 'user.address.city', 'NY')` создаст `user` и `address`) и так же дополнить уже существующее дерево.

Индекс массива считается с нуля. Если индекса нет: **чтение** ведёт себя как «пути нет» (SQL `NULL`, `EXIST` = `FALSE`); **запись** — исключение. Массив не растягивается дырками: при 5 элементах `SET` в `[10]` нельзя. `ADD_*` всегда дописывает в конец. `INS_*` вставляет при индексе от `0` до текущего `LEN` включительно (вставка в конец допустима).

### 1.4. SQL NULL и JSON `null`

В JSON есть своё значение `null`. В SQL — `NULL`. Пакеты их различают так:

| Ситуация | `GET_S` / `GET_I` / `GET_L` / `GET_F` / `GET_B` / `GET_D` | `GET` (узел как JSON) | `EXIST` | `IS_NULL` |
|----------|-----------------------------------------------|------------------------|---------|-----------|
| Пути нет | SQL `NULL` | SQL `NULL` | `FALSE` | `FALSE` |
| На пути стоит JSON `null` | SQL `NULL` | текст `null` | `TRUE` | `TRUE` |
| Значение есть | значение | JSON-текст узла | `TRUE` | `FALSE` |

Пустая JSON-строка `""` — это значение, не NULL: `GET_S` вернёт пустой VARCHAR.

Запись: SQL `NULL` в значении `SET_S` / `SET_I` / `SET_L` / `SET_F` / `SET_B` / `SET_D` / `SET_J` (и тех же `SET_AT_*`) пишет в JSON `null` — как `SET_NULL`. Ключ или документ на выходе сохраняется. SQL `NULL` в самом JSON или в пути по-прежнему даёт SQL `NULL` (запись не выполняется).

Скаляры приводятся как в JsonDataObjects: `"10"` можно прочитать через `GET_I` как `10`. Объект или массив в типизированный get (`GET_S`, `GET_I`, …) не приводятся — будет исключение. Число, которое не помещается в `INTEGER`, в `GET_I` тоже исключение (не тихое обрезание).

Нет пути: `GET_TYPE`, `LEN`, `INDEXOF`, `NAMEOF` → SQL `NULL`. `LEN` у скаляра (не объект и не массив) → SQL `NULL`.

---

## 2. Полный перечень функций и процедур в UDR

Ниже — **все** функции и процедуры пакетов `SJSON` и `BJSON`. Имена и смысл совпадают; отличается только тип самого JSON (VARCHAR или BLOB, см. таблицу пакетов в начале).

Первый аргумент везде, где написано `json`, — JSON-текст **или ключ** после `PARSE` / `CLONE` / `NEW_OBJKEY` / `NEW_ARRKEY` (§1.1–1.2). Второй аргумент `path` — путь внутри JSON (§1.3). Пустая строка пути `''` — корень.

Колонка **Тип**:

- **Функция** — возвращает одно значение. Можно в `SELECT` и в присваивании: `v = SJSON.GET_S(j, 'name')`.
- **Команда** — меняет JSON или буфер ключей. В SQL это тоже function: результат **нужно присвоить** (`j = SJSON.SET_S(j, 'name', 'Ivan')`). Иначе переменная в PSQL не изменится.
- **Процедура** — набор строк: `select * from SJSON.NODES(j, '', true)`.

В колонке **Возврат** слово **JSON** значит VARCHAR в `SJSON` и BLOB в `BJSON`.

Разбор `PARSE` / `CLONE` / `Free`, вырезание `EXTRACTJSON` / `EXTRACTKEY`, колонки `NODES` / `ITEMS` подробно описаны в §3–§6. Здесь — полный список и краткий смысл каждой.

### 2.1. Чтение

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `GET_S(json, path [, value_if_null])` | Функция | `VARCHAR(8191)` | строка (без JSON-кавычек) |
| `GET_I(json, path [, value_if_null])` | Функция | `INTEGER` | целое |
| `GET_L(json, path [, value_if_null])` | Функция | `BIGINT` | длинное целое |
| `GET_F(json, path [, value_if_null])` | Функция | `DOUBLE PRECISION` | число с дробной частью |
| `GET_B(json, path [, value_if_null])` | Функция | `BOOLEAN` | логическое |
| `GET_D(json, path [, value_if_null])` | Функция | `TIMESTAMP` | дата-время (JDO `.D`) |
| `GET(json, path)` | Функция | JSON | узел целиком как JSON-текст: объект, массив или скаляр (`"str"`, `10`, `true`, текст `null`) |
| `GET_TYPE(json, path)` | Функция | `VARCHAR(32)` | `null`, `String`, `Integer`, `Long`, `Float`, `Bool`, `Array`, `Object`, `DateTime` |
| `EXIST(json, path)` | Функция | `BOOLEAN` | такой путь есть |
| `IS_NULL(json, path)` | Функция | `BOOLEAN` | на пути именно JSON `null` (не «поля нет») |
| `LEN(json, path)` | Функция | `INTEGER` | число ключей объекта или элементов массива |
| `INDEXOF(json, path)` | Функция | `INTEGER` | номер последнего сегмента пути среди соседей (ключ объекта или индекс массива); нет → SQL `NULL` |
| `NAMEOF(json, path, index)` | Функция | `VARCHAR(8191)` | имя i-го ключа объекта по `path`; нет объекта / выход за границу → SQL `NULL` |

Нет пути → у `GET_*` / `GET` / `GET_TYPE` / `LEN` SQL `NULL`, у `EXIST` и `IS_NULL` — `FALSE`. JSON `null` на пути: типизированный `GET_S` / `GET_I` / … → SQL `NULL`, `GET` → текст `null`, `EXIST` и `IS_NULL` → `TRUE`.

У `GET_S` / `GET_I` / `GET_L` / `GET_F` / `GET_B` / `GET_D` (и тех же `GET_AT_*`) третий аргумент `value_if_null` по умолчанию SQL `NULL`. Если его не передать, поведение как раньше. Если передать — при SQL `NULL` (нет пути, JSON `null`, NULL-документ) вернётся он, без `COALESCE` снаружи. Пустая строка `''` — не NULL, подмена не срабатывает. У `GET`, `GET_TYPE`, `LEN`, `INDEXOF`, `NAMEOF` этого аргумента нет.

### 2.2. Чтение элемента массива (`GET_AT`)

`GET_AT` берёт элемент **того массива, который передан в первом аргументе**, по числовому индексу. Параметра пути у этих функций нет: массив — это сам `json`.

Откуда взять массив:

- документ уже является массивом (`[ ... ]`) — передаёте его как есть: `GET_AT(j, 0)` то же самое, что `GET(j, '[0]')` (путь от корня — пустой, дальше только индекс);
- массив лежит внутри объекта — либо обычный путь: `GET_S(j, 'items[0].name')`, либо сначала достать массив и вызвать `GET_AT` уже по нему: `GET_AT(SJSON.GET(j, 'items'), 0)`.

Если в `json` не массив, будет исключение. Индекс с нуля. Отрицательный — исключение. Слишком большой на чтении — SQL `NULL` (как «элемента нет»).

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `GET_AT_S(json, index [, value_if_null])` | Функция | `VARCHAR(8191)` | строка элемента |
| `GET_AT_I(json, index [, value_if_null])` | Функция | `INTEGER` | целое |
| `GET_AT_L(json, index [, value_if_null])` | Функция | `BIGINT` | длинное целое |
| `GET_AT_F(json, index [, value_if_null])` | Функция | `DOUBLE PRECISION` | число с дробной частью |
| `GET_AT_B(json, index [, value_if_null])` | Функция | `BOOLEAN` | логическое |
| `GET_AT_D(json, index [, value_if_null])` | Функция | `TIMESTAMP` | дата-время |
| `GET_AT(json, index)` | Функция | JSON | элемент как JSON (как `GET`) |
| `GET_AT_TYPE(json, index)` | Функция | `VARCHAR(32)` | тип элемента |

### 2.3. Запись по пути (`SET`)

Возвращают JSON: новый текст, если на вход дали текст, или **тот же ключ**, если на вход дали ключ. Недостающие объекты на пути создаются; существующие не трогаются. Индекс массива за границей — исключение (массив дырками не растягивается).

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `SET_S(json, path, value)` | Команда | JSON | записать строку; SQL `NULL` → JSON `null` |
| `SET_I(json, path, value)` | Команда | JSON | записать INTEGER; SQL `NULL` → JSON `null` |
| `SET_L(json, path, value)` | Команда | JSON | записать BIGINT; SQL `NULL` → JSON `null` |
| `SET_F(json, path, value)` | Команда | JSON | записать DOUBLE PRECISION; SQL `NULL` → JSON `null` |
| `SET_B(json, path, value)` | Команда | JSON | записать BOOLEAN; SQL `NULL` → JSON `null` |
| `SET_D(json, path, value)` | Команда | JSON | записать TIMESTAMP (JDO `.D`); SQL `NULL` → JSON `null` |
| `SET_NULL(json, path)` | Команда | JSON | записать JSON `null` |
| `SET_J(json, path, json_value)` | Команда | JSON | подставить узел: объект `{...}`, массив `[...]` или скаляр (`"hi"`, `10`, `true`, `null`). `json_value` — JSON-текст или ключ (копируется дерево); SQL `NULL` → JSON `null` |

В **BJSON** у `SET_J`, `ADD_J` и `INS` аргумент `json_value` — BLOB (либо ключ). Скаляры `SET_S` / `GET_S` всегда `VARCHAR`, в том числе в BJSON.

### 2.4. Запись элемента массива (`SET_AT`)

Как `GET_AT`: в первом аргументе должен быть массив, индекс — номер элемента. Вложенный массив задаётся тем же способом: либо путь `SET_S(j, 'items[0].name', ...)`, либо `SET_AT` по JSON/ключу, который уже указывает на этот массив.

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `SET_AT_S(json, index, value)` | Команда | JSON | записать строку в элемент; SQL `NULL` → JSON `null` |
| `SET_AT_I(json, index, value)` | Команда | JSON | записать INTEGER; SQL `NULL` → JSON `null` |
| `SET_AT_L(json, index, value)` | Команда | JSON | записать BIGINT; SQL `NULL` → JSON `null` |
| `SET_AT_F(json, index, value)` | Команда | JSON | записать DOUBLE PRECISION; SQL `NULL` → JSON `null` |
| `SET_AT_B(json, index, value)` | Команда | JSON | записать BOOLEAN; SQL `NULL` → JSON `null` |
| `SET_AT_D(json, index, value)` | Команда | JSON | записать TIMESTAMP; SQL `NULL` → JSON `null` |
| `SET_AT_NULL(json, index)` | Команда | JSON | JSON `null` в ячейке |
| `SET_AT_J(json, index, json_value)` | Команда | JSON | подставить узел в ячейку |
| `REMOVE_AT(json, index)` | Команда | JSON | удалить элемент с этим индексом |

### 2.5. Добавление, вставка, удаление

`ADD_*` работает **только с массивом** по пути. Если массива ещё нет — он создаётся (и при необходимости недостающие родители на пути). Если массив уже есть — новые элементы только дописываются **в конец**, существующие не меняются.

`INS_*` вставляет на позицию `index` (`0` … текущая длина массива включительно: можно вставить в конец).

`CLEAR` / `ASSIGN` / `DELETEOF` / `SET_LEN` меняют уже существующий узел: опустошить, залить содержимое, удалить поле объекта по номеру, задать длину массива. Это не `ADD_*`.

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `ADD_S(json, path, value)` | Команда | JSON | дописать строку в конец массива |
| `ADD_I(json, path, value)` | Команда | JSON | дописать INTEGER |
| `ADD_L(json, path, value)` | Команда | JSON | дописать BIGINT |
| `ADD_F(json, path, value)` | Команда | JSON | дописать DOUBLE PRECISION |
| `ADD_B(json, path, value)` | Команда | JSON | дописать BOOLEAN |
| `ADD_D(json, path, value)` | Команда | JSON | дописать TIMESTAMP |
| `ADD_A(json, path)` | Команда | JSON | дописать пустой массив `[]` |
| `ADD_O(json, path)` | Команда | JSON | дописать пустой объект `{}` |
| `ADD_J(json, path, json_value)` | Команда | JSON | дописать узел в конец массива |
| `INS_S(json, path, index, value)` | Команда | JSON | вставить строку в массив |
| `INS_I(json, path, index, value)` | Команда | JSON | вставить INTEGER |
| `INS_L(json, path, index, value)` | Команда | JSON | вставить BIGINT |
| `INS_F(json, path, index, value)` | Команда | JSON | вставить DOUBLE PRECISION |
| `INS_B(json, path, index, value)` | Команда | JSON | вставить BOOLEAN |
| `INS_D(json, path, index, value)` | Команда | JSON | вставить TIMESTAMP |
| `INS_A(json, path, index)` | Команда | JSON | вставить пустой массив `[]` |
| `INS_O(json, path, index)` | Команда | JSON | вставить пустой объект `{}` |
| `INS(json, path, index, json_value)` | Команда | JSON | вставить узел (JSON-текст или ключ) |
| `REMOVE(json, path)` | Команда | JSON | удалить поле объекта или элемент массива по пути |
| `EXTRACTJSON(json, path)` | Команда | JSON-текст | вырезать узел, вернуть его как JSON (как `GET`). Если на вход ключ — родитель меняется на месте |
| `EXTRACTKEY(json, path)` | Команда | `CHAR(36)` | вырезать объект/массив, вернуть **новый** ключ на этот узел. Скаляр — исключение |
| `CLEAR(json, path)` | Команда | JSON | опустошить объект или массив на месте (`{}` / `[]`); `path = ''` — корень; нет пути / не объект и не массив — исключение |
| `ASSIGN(json, path, source)` | Команда | JSON | залить содержимое `source` (текст или ключ) в узел по `path`; `path = ''` — корень (типы должны совпасть) |
| `DELETEOF(json, path, index)` | Команда | JSON | удалить i-е поле **объекта** (массив — `REMOVE_AT`) |
| `SET_LEN(json, path, n)` | Команда | JSON | записать `.Count` массива (`n >= 0`); объект — исключение |

### 2.6. Конструкторы и сериализация

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `NEW_OBJECT()` | Функция | JSON | пустой объект, текст `{}` |
| `NEW_ARRAY()` | Функция | JSON | пустой массив, текст `[]` |
| `NEW_OBJKEY()` | Команда | `CHAR(36)` | пустой объект сразу в буфере ключей |
| `NEW_ARRKEY()` | Команда | `CHAR(36)` | пустой массив сразу в буфере ключей |
| `ToJSON(key [, compact])` | Функция | JSON | сериализовать дерево по ключу (или по JSON-тексту). `compact` по умолчанию `1` (одна строка); `0` — с отступами |
| `KeySize(json [, compact])` | Функция | `INTEGER` | число символов того текста, который вернул бы `ToJSON` с тем же `compact`. Для ключа — без выгрузки документа в Firebird. В `SJSON` можно проверить, влезет ли в `VARCHAR(8191)` |

`NEW_OBJECT` / `NEW_ARRAY` ключ **не** создают. Для работы через ключ — `NEW_OBJKEY` / `NEW_ARRKEY`, `PARSE` или `CLONE`.

### 2.7. Ключ сессии: `PARSE`, `CLONE` и `Free`

Подробности — в §3.

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `PARSE(json)` | Команда | `CHAR(36)` | разобрать JSON-текст, положить в буфер UDR, вернуть ключ |
| `CLONE(json)` | Команда | `CHAR(36)` | независимая копия дерева; **всегда новый ключ**, даже если на вход уже ключ |
| `EXTRACTJSON(json, path)` | Команда | JSON | вырезать узел, вернуть JSON-текст |
| `EXTRACTKEY(json, path)` | Команда | `CHAR(36)` | вырезать объект/массив, вернуть новый ключ |
| `Free(key)` | Команда | `BOOLEAN` | удалить JSON — очистить буфер UDR по ключу. Повторный вызов → `FALSE`. SQL `NULL` → `NULL` |

### 2.8. Процедуры обхода

Подробности — колонки и правила в §4 и §5.

| Имя | Тип | Возврат | Смысл |
|-----|-----|---------|--------|
| `NODES(json, path [, full_path])` | Процедура | набор строк | обойти дерево в глубину, начиная с `path` |
| `ITEMS(json, path)` | Процедура | набор строк | один уровень массива: строка на каждое поле каждого элемента |

Вызов:

```sql
select * from SJSON.NODES(:j, 'address', true);
select * from SJSON.ITEMS(:j, 'phoneNumbers');
```

---

## 3. PARSE / CLONE / Free

`PARSE` кладёт JSON в отдельный буфер UDR и возвращает ключ. Дальше `GET_*` / `SET_*` вызывают с этим ключом вместо текста: без повторного разбора и без сериализации после каждой правки.

`CLONE(json)` всегда возвращает **новый** ключ: и с JSON-текста, и с уже существующего ключа. Исходный документ не меняется. Копию нужно `Free`, как ключ от `PARSE`.

```sql
k = SJSON.PARSE('{"user":{"name":"Ivan"}}');
c = SJSON.CLONE(k);          -- другой ключ, то же содержимое
c = SJSON.SET_I(c, 'user.id', 1);
-- k по-прежнему без id; c — с id
```

Текст по ключу — только через `ToJSON(ключ)`. Длина этого текста в символах — `KeySize(ключ)` (тот же `compact`, по умолчанию `1`): `CHAR_LENGTH(ToJSON(k))` без передачи всего JSON в Firebird. Ключ живёт до `Free(ключ)` или до конца сессии Firebird. До уничтожения им можно пользоваться из любой процедуры, триггера или функции **этого подключения** (включая `SJSON` и `BJSON`).

Типичный цикл:

```sql
execute block returns (s varchar(8191))
as
  declare k char(36);
  declare ok boolean;
begin
  k = SJSON.PARSE('{"user":{"name":"Ivan"}}');
  k = SJSON.SET_I(k, 'user.id', 10);       -- тот же ключ
  s = SJSON.ToJSON(k);                     -- {"user":{"name":"Ivan","id":10}}
  ok = SJSON.Free(k);                      -- TRUE; повторный Free даст FALSE
  suspend;
end
```

---

## 4. NODES

Процедура обходит JSON **в глубину**, начиная с узла `A_PATH` (пустая строка или SQL `NULL` — с корня). Каждая строка — один узел: сначала объект/массив-заголовок, затем дети.

```sql
select * from SJSON.NODES(:j, 'address', true);
```

| Параметр | Смысл |
|----------|--------|
| `A_JSON` | JSON-текст или ключ |
| `A_PATH` | откуда начать; `NULL` = корень |
| `A_FULL_PATH` | `TRUE` (по умолчанию) — колонка `PATH` от корня всего JSON; `FALSE` — путь только от узла старта (у первой строки `PATH` пустой) |

| Колонка | Смысл |
|---------|--------|
| `ABS_INDEX` | 0, 1, 2… **в этом вызове** (узел, с которого начали = 0), не «номер во всём файле» |
| `LOC_INDEX` | у объекта/массива — сколько детей; у поля объекта — номер ключа среди соседей; у элемента массива — `n` |
| `NAME` | имя поля; у элемента массива `'[n]'`; у корня JSON — пусто |
| `PATH` | см. `A_FULL_PATH` |
| `TYP` | как `GET_TYPE` |
| `VAL` | скаляр как `GET_S` (пустая строка — пустое поле, не `""`); число / `true` / `false` текстом; JSON `null` → **SQL NULL**; объект/массив — только маркеры `{}` / `[]`, без полного содержимого (дети идут следующими строками) |

Нет такого пути или `A_JSON` SQL `NULL` → 0 строк, не исключение.

---

## 5. ITEMS

Процедура смотрит **один уровень массива**, без обхода вложенных полей. Если элементы — объекты, на каждый ключ каждого элемента — своя строка. Так массив объектов превращается в таблицу «номер строки + имя поля + значение».

```sql
select * from SJSON.ITEMS(:j, 'phoneNumbers');
```

| Колонка | Смысл |
|---------|--------|
| `LOC_INDEX` | индекс элемента массива (0, 1, …) |
| `NAME` | имя поля внутри объекта; если элемент — скаляр, массив или JSON `null` — `'[n]'` |
| `TYP` | как `GET_TYPE` |
| `VAL` | скаляр как в `NODES` (JSON `null` → SQL NULL); вложенный объект/массив — **весь** компактный JSON (как `GET`), потому что внутрь процедура не спускается |

Пустой массив, нет пути, `A_JSON` SQL `NULL` → 0 строк. Если по пути не массив (объект, скаляр, JSON `null`) → исключение `ITEMS path is not an array`.

Firebird не умеет «сколько ключей в JSON — столько колонок SELECT». Имена полей приходят в колонке `NAME`; широкую таблицу собирает клиент или PSQL, если схема заранее известна (`GET_S`).

---

## 6. EXTRACTJSON / EXTRACTKEY

Функции вырезают узел по пути (как `REMOVE`) и возвращают **сам узел**, не родителя. Корень (`path = ''`) вырезать нельзя.

| Имя | Возврат | Что вырезает |
|-----|---------|----------------|
| `EXTRACTJSON(json, path)` | JSON-текст (VARCHAR / BLOB) | любой узел, как `GET` |
| `EXTRACTKEY(json, path)` | `CHAR(36)` | только объект или массив; скаляр / JSON `null` — исключение |

Если на вход **ключ** — узел удаляется из этого дерева на месте; тот же ключ дальше указывает на родителя без узла. Если на вход **JSON-текст** — исходная строка у вызывающего не меняется (вырезание идёт с копии).

```sql
execute block
returns (extracted varchar(8191), k char(36), left_over varchar(8191))
as
  declare src char(36);
begin
  src = SJSON.PARSE('{"user":{"id":1,"addr":{"city":"NY"}}}');
  extracted = SJSON.EXTRACTJSON(src, 'user.id');   -- 1
  k = SJSON.EXTRACTKEY(src, 'user.addr');          -- новый ключ на {"city":"NY"}
  left_over = SJSON.ToJSON(src);                   -- {"user":{}}
  suspend;
end
```

Нет такого пути → SQL `NULL`. SQL `NULL` в `A_JSON` или `A_PATH` → SQL `NULL`. `REMOVE` удаляет без возврата узла; `CLEAR` оставляет пустой объект/массив на месте.

---

## 7. Сопоставление с Delphi JsonDataObjects (JDO)

Чтение в пакетах **не создаёт** отсутствующие узлы (в JDO чтение `Path` / `O[]` / `A[]` их создаёт). Нет поля → SQL `NULL`, а не `''` / `0` / `false`. На записи недостающие узлы по пути создаются, уже существующие остаются.

| PxrJSON | JDO | Примечание |
|---------|-----|------------|
| первый аргумент (JSON-текст) | `Parse` / `ParseUtf8` / `FromJSON` | разбор при вызове |
| `PARSE` | — | дерево в кэше сессии, возврат UUID |
| `CLONE` | `Clone` | **всегда** новый ключ, и с текста, и с ключа |
| `Free` | — | только ключ PARSE/CLONE; повтор → `FALSE` |
| `ToJSON(key, compact)` | `ToJSON(Compact)` / `ToString` | `compact` 1 / 0 |
| `NEW_OBJECT()` | `TJsonObject.Create` | JSON `{}` |
| `NEW_ARRAY()` | `TJsonArray.Create` | JSON `[]` |
| `NEW_OBJKEY()` / `NEW_ARRKEY()` | — | пустой объект/массив сразу в кэше |
| `GET_S` / `GET_I` / `GET_L` / `GET_F` / `GET_B` / `GET_D` | `.S` / `.I` / `.L` / `.F` / `.B` / `.D`, чтение `Path[]` | чтение не создаёт узлы |
| `SET_S` / `SET_I` / `SET_L` / `SET_F` / `SET_B` / `SET_D` | запись `.S` / `.D` / `Path[]` | нет узла на пути — создаётся; есть — не пересоздаётся; SQL `NULL` в value → JSON `null` |
| `GET` | `.O` / `.A` / узел целиком | в SQL — JSON-текст, не объект Delphi |
| `SET_J` | запись `.O` / `.A` / разбор литерала в `Path` | текст JSON или ключ (копия) |
| `SET_NULL` | `null` в свойстве (`O[name] := nil`) | |
| `GET_AT_*` / `SET_AT_*` | массив `.S[i]` / `.I[i]` / `.D[i]` / … | первый аргумент — массив; индекс `INTEGER` |
| `GET_TYPE` / `GET_AT_TYPE` | `Types[name]` / `Types[i]` | плюс `'null'` для JSON `null`; для `.D` — `'DateTime'` |
| `LEN` | `.Count` | объект и массив; скаляр → SQL `NULL` |
| `SET_LEN` | запись `.Count` | только массив; `n < 0` — исключение |
| `INDEXOF` | `IndexOf(name)` / индекс сегмента `[n]` | нет ключа → SQL `NULL` |
| `NAMEOF` | `Names[i]` | нет / за границей → SQL `NULL` |
| `EXIST(json, path)` | частично `Contains(name)` | JDO — один ключ, не путь `a.b` |
| `IS_NULL` | `IsNull(name)` / `IsNull(i)` | в JDO часто `True` и когда ключа нет; здесь только явный JSON `null` |
| `ADD_*` / `ADD_J` / `ADD_A` / `ADD_O` | `Add(...)` / `AddArray` / `AddObject` | только массив |
| `INS_*` / `INS` / `INS_A` / `INS_O` | `Insert(index, ...)` / `InsertArray` / `InsertObject` | индекс `0 .. Count` |
| `REMOVE` | `Remove(name)` | в PxrJSON — по пути, не только ключ корня |
| `REMOVE_AT` | `Delete(index)` массива | |
| `DELETEOF` | `Delete(index)` объекта | |
| `CLEAR` | `Clear` | объект или массив по пути |
| `ASSIGN` | `Assign` | `source` — JSON-текст или ключ |
| `EXTRACTJSON` / `EXTRACTKEY` | `Extract` / `ExtractObject` / `ExtractArray` | возврат — вырезанный узел (текст или новый ключ); родитель меняется при входе-ключе |
| `NODES` | — | обход дерева строками |
| `ITEMS` | — | один уровень массива как таблица полей |

`.U` (UInt64) и `.DUtc` в SQL нет.

---

## 8. Примеры

Пакет `SJSON`. Для BLOB замените на `BJSON` и тип переменной на `BLOB SUB_TYPE TEXT CHARACTER SET UTF8`.

Ниже вызовы как в PSQL: переменная, присваивание функции, `suspend`. Так же можно писать в хранимых процедурах.

### 8.1. Человек (классический пример JSON)

Источник: [JSON, Wikipedia](https://en.wikipedia.org/wiki/JSON) / стиль json.org.

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

Чтение полей:

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

  first_name = SJSON.GET_S(j, 'firstName');           -- John  (парсинг в буфер UDR)
  age = SJSON.GET_I(j, 'age');                        -- 27
  is_alive = SJSON.GET_B(j, 'isAlive');               -- TRUE
  city = SJSON.GET_S(j, 'address.city');              -- New York
  home_phone = SJSON.GET_S(j, 'phoneNumbers[0].number');
  spouse_type = SJSON.GET_TYPE(j, 'spouse');          -- null
  spouse_s = SJSON.GET_S(j, 'spouse');                -- SQL NULL
  spouse_json = SJSON.GET(j, 'spouse');               -- текст null
  spouse_exist = SJSON.EXIST(j, 'spouse');            -- TRUE
  spouse_is_null = SJSON.IS_NULL(j, 'spouse');        -- TRUE
  has_middle = SJSON.EXIST(j, 'middleName');          -- FALSE
  phones = SJSON.LEN(j, 'phoneNumbers');              -- 2
  kids = SJSON.LEN(j, 'children');                    -- 0
  suspend;
end
```

В этом примере исходный JSON не меняется. Парсинг JSON внутри UDR проходит один раз — в первой строке; в остальных вызовах дерево берётся из буфера.

Сменить город и дописать телефон — результат `SET` / `ADD` записываем обратно в `j`:

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

Обход адреса и таблица телефонов (процедуры по-прежнему через `select`, внутри блока — `for … in`):

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

### 8.2. Меню (пример с json.org)

Источник: [json.org/example.html](https://json.org/example.html), объект `menu`.

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

  menu_id = SJSON.GET_S(j, 'menu.id');                 -- file  (парсинг в буфер UDR)
  menu_value = SJSON.GET_S(j, 'menu.value');           -- File
  item_count = SJSON.LEN(j, 'menu.popup.menuitem');    -- 3
  open_handler = SJSON.GET_S(j, 'menu.popup.menuitem[1].onclick'); -- OpenDoc()

  j = SJSON.INS(j, 'menu.popup.menuitem', 0,
                '{"value":"Save","onclick":"SaveDoc()"}');
  j2 = SJSON.ToJSON(j);
  suspend;
end
```

В этом примере при чтении исходный JSON не меняется. Парсинг JSON внутри UDR проходит один раз — в первой строке; в остальных `GET_*` / `LEN` дерево берётся из буфера. `INS` — уже запись: в `j` попадает новый JSON-текст.

Пустой массив или объект вставляют `INS_A` / `INS_O` (без JSON-литерала). `CLEAR` опустошает узел на месте:

```sql
j = SJSON.INS_O(j, 'menu.popup.menuitem', 0);   -- {} в начало списка
j = SJSON.SET_S(j, 'menu.popup.menuitem[0].value', 'Save');
j = SJSON.CLEAR(j, 'menu.popup');               -- popup = {}
```

Пункты меню как таблица:

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

### 8.3. Посты (массив в корне, стиль JSONPlaceholder)

Источник: [JSONPlaceholder](https://jsonplaceholder.typicode.com/posts).

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

Корень этого примера — массив. Элемент можно взять путём `'[n].…'` или `GET_AT` (первый аргумент уже массив):

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

  cnt = SJSON.LEN(j, '');                 -- 2  (парсинг в буфер UDR)
  root_type = SJSON.GET_TYPE(j, '');      -- Array
  first_id = SJSON.GET_I(j, '[0].id');    -- 1
  second_id = SJSON.GET_I(j, '[1].id');   -- 2
  first_post = SJSON.GET_AT(j, 0);        -- {"userId":1,"id":1,...}
  suspend;
end
```

В этом примере исходный JSON не меняется. Парсинг JSON внутри UDR проходит один раз — в первой строке; в остальных вызовах дерево берётся из буфера.

Разобрать один раз, править по ключу, отдать текст:

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

Собрать JSON с нуля (каждый `SET` возвращает JSON — пишем в ту же переменную):

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

То же через ключ: между `SET` текст не передаётся между Firebird и UDR, прилетает из UDR один раз в конце через `ToJSON`.

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

### 8.4. Повторные вызовы: без `PARSE` и через `PARSE`

Реальный замер. JSON **63.8 Kb**, **10 000** повторных `BJSON.GET_S` одного и того же пути.

Без `PARSE` каждый вызов передаёт весь BLOB из Firebird в UDR. Через `PARSE` в цикле ходит только ключ, дерево уже в буфере UDR.

- Без `PARSE`: <span style="background-color:#ffc9c9;font-weight:700">Execute time = 4s 250ms</span>
- Через `PARSE`: <span style="color:#1565c0;font-weight:700">Execute time = 218ms</span>

Пример работы без `PARSE`.

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
Avg fetch time = 4 250,00 ms  
Current memory = 10 642 348 816  
Max memory = 10 645 710 080  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 80 044  

Пример работы через `PARSE`.

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
Avg fetch time = 218,00 ms  
Current memory = 10 643 868 224  
Max memory = 10 646 153 712  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 52  

### 8.5. Тот же замер через `SJSON` (JSON «Человек»)

Реальный замер. JSON из §8.1, пакет `SJSON` (`VARCHAR`), **100 000** повторных `GET_S`.

На коротком тексте разница с `PARSE` небольшая: UDR и так помнит последние 64 уникальных JSON, а `VARCHAR` между Firebird и UDR передаётся дёшево.

- Без `PARSE`: <span style="background-color:#ffc9c9;font-weight:700">Execute time = 2s 313ms</span>
- Через `PARSE`: <span style="color:#1565c0;font-weight:700">Execute time = 1s 938ms</span>

Пример работы без `PARSE`.

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
Avg fetch time = 2 313,00 ms  
Current memory = 10 642 373 040  
Max memory = 10 646 163 504  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 32  

Пример работы через `PARSE`.

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
Avg fetch time = 1 938,00 ms  
Current memory = 10 642 494 384  
Max memory = 10 646 163 504  
Memory buffers = 625 000  
Reads from disk to cache = 0  
Writes from cache to disk = 0  
Fetches from cache = 40  

**Вывод**

<table>
  <tr>
    <th></th>
    <th>§8.4 <code>BJSON</code>, 63.8 Kb, 10 000 вызовов</th>
    <th>§8.5 <code>SJSON</code>, «Человек», 100 000 вызовов</th>
  </tr>
  <tr>
    <td>Без <code>PARSE</code></td>
    <td><span style="background-color:#ffc9c9;font-weight:700">Execute time = 4s 250ms</span>, Fetches = 80 044</td>
    <td><span style="background-color:#ffc9c9;font-weight:700">Execute time = 2s 313ms</span>, Fetches = 32</td>
  </tr>
  <tr>
    <td>Через <code>PARSE</code></td>
    <td><span style="color:#1565c0;font-weight:700">Execute time = 218ms</span>, Fetches = 52</td>
    <td><span style="color:#1565c0;font-weight:700">Execute time = 1s 938ms</span>, Fetches = 40</td>
  </tr>
</table>

Почему на коротком `VARCHAR` `PARSE` почти не помогает:

- UDR и так помнит последние **64** уникальных JSON-текста — повторный `GET_S` с тем же `a_json` не разбирает строку заново;
- передать `VARCHAR` между Firebird и UDR дёшево, в отличие от BLOB (страницы BLOB, 80 044 fetch против 32).

`PARSE` имеет смысл, когда JSON **большой** (как в §8.4) или его **правят** через `SET_*`: между правками текст не гоняется туда-обратно, в Firebird он возвращается один раз через `ToJSON`.
