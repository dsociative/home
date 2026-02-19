+++
title = "Join событий из двух Kafka-топиков без внешних фреймворков"
date = 2026-02-19
lastmod = 2026-02-19
tags = ["kafka", "join", "stream-processing", "distributed-systems", "rust", "rdkafka", "left-join", "one-to-many"]
draft = false
description = "Подходы к join событий из двух Kafka-топиков без Kafka Streams, Flink и ksqlDB — только consumer/producer API. Разбор случая когда join key лежит в теле сообщения, а топики имеют разную топологию."
+++

Задача: объединить (join) события из двух Kafka-топиков по общему ключу, не используя Kafka Streams, Flink, ksqlDB и другие stream-processing фреймворки. Только consumer/producer API и минимальный код.


## Фундаментальная проблема: co-partitioning {#фундаментальная-проблема-co-partitioning}

Прежде чем рассматривать подходы, нужно понять ключевое ограничение. Kafka consumer читает партиции, а не топики целиком. Если два топика партиционированы по-разному (разное количество партиций или разная стратегия партиционирования), то события с одинаковым ключом могут оказаться в разных партициях, назначенных разным consumer-ам.

Для корректного partition-local join **обязательно**:

-   Одинаковое количество партиций в обоих топиках
-   Одинаковая стратегия партиционирования (один и тот же partitioner по одному и тому же ключу)
-   Consumer подписан на обе соответствующие партиции (assign вручную или одна consumer group на оба топика)

Если co-partitioning нарушен, необходимо либо repartitioning (см. [соответствующий раздел](#подход-4-repartitioning-промежуточный-топик)), либо глобальный подход (compacted topic как lookup table, база данных).

Это то, что Kafka Streams делает автоматически: проверяет co-partitioning при старте и падает с ошибкой `TopologyException` при несовпадении ([Confluent: How Co-Partitioning Works in Kafka Streams](https://www.confluent.io/blog/co-partitioning-in-kafka-streams/)).


## Подход 1: Client-side join с in-memory store {#подход-1-client-side-join-с-in-memory-store}


### Как работает {#как-работает}

Consumer подписывается на оба топика (или два consumer-а в одном процессе читают по топику). Входящие события буферизуются в локальном `HashMap<JoinKey, Event>`. Когда по одному ключу пришли события из обоих топиков — формируется joined-результат и отправляется наружу (в выходной топик или в БД).

```text
Topic A ──► Consumer ──┐
                       ├──► HashMap<key, (A?, B?)> ──► emit joined
Topic B ──► Consumer ──┘
```


### Варианты буферизации {#варианты-буферизации}


#### Infinite buffer (unbounded join) {#infinite-buffer--unbounded-join}

Все события хранятся в памяти до прихода пары. Подходит для case, когда **гарантировано** приходят обе стороны и данные не растут бесконечно (например, request-response паттерн).

Проблемы:

-   Утечка памяти, если одна из сторон не пришла (orphan events)
-   Нет TTL — буфер растёт неограниченно при потере событий


#### Windowed join (time-bounded buffer) {#windowed-join--time-bounded-buffer}

Буфер ограничен временным окном. Событие из топика A ждёт пару из топика B в течение окна (например, 5 минут). Если пара не пришла — событие отбрасывается или отправляется в dead letter topic.

```text
window = [event.timestamp - before, event.timestamp + after]
```

Это аналог `JoinWindows` из Kafka Streams ([JoinWindows javadoc](https://kafka.apache.org/31/javadoc/org/apache/kafka/streams/kstream/JoinWindows.html)), но реализованный вручную.

Ключевые решения:

-   **По какому времени окно?** Event time (timestamp из сообщения) vs. processing time (wall clock). Event time корректнее, но требует обработки out-of-order событий.
-   **Размер окна** — trade-off: большое окно = больше памяти, но ловит late events; маленькое окно = меньше памяти, но теряет опоздавшие.
-   **Eviction policy** — по таймеру, по watermark или по количеству элементов.


### Семантики доставки {#семантики-доставки}

**At-least-once**: commit offset после emit joined-результата. При рестарте часть событий перечитается и может быть re-joined (дубликаты). Обработчик должен быть идемпотентным.

**Exactly-once**: использовать Kafka transactions — читать из обоих топиков, формировать joined-результат, записывать в выходной топик и коммитить offset **атомарно** в одной транзакции ([Confluent: Transactions in Apache Kafka](https://www.confluent.io/blog/transactions-apache-kafka/)).

```text
producer.beginTransaction()
producer.send(joined_record)
producer.sendOffsetsToTransaction(offsets, consumerGroupId)
producer.commitTransaction()
```


### Восстановление при рестарте {#восстановление-при-рестарте}

Главная проблема: in-memory state **теряется** при рестарте. Варианты:

1.  **Перечитать оба топика с начала** — если топики небольшие или retention позволяет. Медленный, но простой подход.
2.  **Хранить state в changelog topic** — перед каждым изменением буфера писать запись в компактированный топик. При рестарте — восстановить state из changelog. Это именно то, что Kafka Streams делает с RocksDB + changelog ([Kafka Streams Internal Data Management](https://cwiki.apache.org/confluence/display/KAFKA/Kafka+Streams+Internal+Data+Management)).
3.  **Periodic snapshots** — периодически сериализовать буфер на диск. При рестарте — загрузить snapshot + дочитать недостающие offset-ы.


### Rebalancing {#rebalancing}

При rebalance (добавление/удаление consumer-а) партиции переназначаются. Локальный state для потерянных партиций больше не нужен, а для новых — ещё не построен.

Решения:

-   **CooperativeStickyAssignor** — минимизирует переназначение партиций, сохраняя state ([Confluent: Cooperative Rebalancing](https://www.confluent.io/blog/cooperative-rebalancing-in-kafka-streams-consumer-ksqldb/))
-   **Static group membership** (`group.instance.id`) — consumer не вызывает rebalance при коротких перезагрузках
-   При получении `onPartitionsRevoked` — очистить state для отозванных партиций; при `onPartitionsAssigned` — перестроить state для новых


### Когда использовать {#когда-использовать}

-   Оба топика с невысоким throughput и события не копятся долго
-   Join по event time с предсказуемым окном (request в течение N секунд получает response)
-   Допустима потеря state при рестарте (или есть changelog)
-   Простота важнее надёжности


## Подход 2: Compacted topic как lookup table {#подход-2-compacted-topic-как-lookup-table}


### Как работает {#как-работает}

Один из топиков — справочник (dimensions/reference data), настроен с `cleanup.policy=compact`. Consumer при старте читает этот топик **с начала** целиком, строит локальную `HashMap<key, value>`. Затем потоково читает второй (event) топик и для каждого события делает lookup в HashMap.

```text
Compacted topic (users) ──► bootstrap: load all → HashMap<userId, User>
Event topic (orders)    ──► stream: for each order → lookup user → emit enriched
```

Это ручная реализация паттерна `GlobalKTable` из Kafka Streams ([Confluent: Kafka Streams Concepts](https://docs.confluent.io/platform/current/streams/concepts.html)).


### Обновления справочника {#обновления-справочника}

Два consumer-а:

1.  **Dimension consumer** — слушает компактированный топик, обновляет HashMap при поступлении новых записей
2.  **Event consumer** — читает поток событий, делает lookup

Порядок важен: dimension consumer должен быть впереди event consumer-а, иначе lookup может вернуть устаревшие данные или `null` для свежих ключей.


### Семантики {#семантики}

**At-least-once** для event stream: стандартный commit-after-process.

Для dimension топика семантика обычно eventual consistency — справочник может отставать на несколько сообщений, и join вернёт слегка устаревшие данные. Для большинства use case-ов (обогащение заказов данными пользователя) это приемлемо.


### Восстановление при рестарте {#восстановление-при-рестарте}

Dimension consumer перечитывает компактированный топик с `auto.offset.reset=earliest`. Kafka log compaction гарантирует, что для каждого ключа хранится как минимум последнее значение ([Confluent: Log Compaction](https://docs.confluent.io/kafka/design/log_compaction.html)).

Время восстановления зависит от размера справочника. Для миллионов записей bootstrap может занять минуты.

Оптимизация: snapshot HashMap на диск + запомнить offset. При рестарте загрузить snapshot и дочитать только новые записи.


### Память {#память}

Весь справочник живёт в heap. Оценка: если в компактированном топике 10M записей по ~1 KB = ~10 GB RAM. Для больших справочников — использовать [embedded store](#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite) или [внешнюю БД](#подход-5-database-backed-join).


### Gotchas {#gotchas}

-   **Compaction не мгновенна** — Kafka запускает compaction в фоне. Consumer может увидеть несколько версий одного ключа при bootstrap. HashMap перезаписывает значение — это корректно, но нужно знать.
-   **Tombstone records** (`value=null`) — означают удаление. Consumer должен удалять запись из HashMap при получении tombstone.
-   **Нет co-partitioning requirement** — dimension topic читается целиком, join не partition-local. Это главное преимущество перед подходом 1.
-   **Cold start** — первый запуск медленный: нужно прочитать весь справочник перед началом обработки событий.


### Когда использовать {#когда-использовать}

-   Один из топиков — относительно статичный справочник (пользователи, продукты, конфиги)
-   Справочник помещается в память (или во встроенную БД)
-   Не нужен двусторонний join (stream-stream), только обогащение
-   Допустима eventual consistency справочника


## Подход 3: Embedded state store (RocksDB, BadgerDB, SQLite) {#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite}


### Как работает {#как-работает}

Вместо `HashMap` в памяти используется встроенная key-value БД. Принцип тот же, что и в подходах 1 и 2, но state хранится на диске и переживает рестарт.

```text
Topic A ──► Consumer ──┐
                       ├──► RocksDB/BadgerDB ──► emit joined
Topic B ──► Consumer ──┘
```

Это ровно то, что делает Kafka Streams под капотом: RocksDB как default state store + changelog topic для восстановления при потере диска ([Confluent: Performance Tuning RocksDB for Kafka Streams](https://www.confluent.io/blog/how-to-tune-rocksdb-kafka-streams-state-stores-performance/)).


### Выбор embedded store {#выбор-embedded-store}

| Store        | Язык                              | Особенности                                                |
|--------------|-----------------------------------|------------------------------------------------------------|
| **RocksDB**  | C++ (bindings для Java, Go, Rust) | Стандарт Kafka Streams, LSM-tree, высокий write throughput |
| **BadgerDB** | Go                                | LSM-tree, нативный Go, ACID transactions                   |
| **SQLite**   | C (bindings везде)                | SQL-интерфейс, проще для сложных join-ов                   |
| **Pebble**   | Go                                | RocksDB-совместимый, используется в CockroachDB            |
| **LMDB**     | C                                 | B-tree, быстрые reads, zero-copy                           |


### Семантики {#семантики}

**At-least-once**: записать в store, затем commit offset. При рестарте — state уже на диске, повторно обработанные сообщения перезапишут те же ключи (идемпотентно).

**Exactly-once**: записать в store + записать offset **в тот же store** (а не в Kafka `__consumer_offsets`). Ручной offset management через `consumer.seek()` при старте. Атомарность обеспечивается транзакцией store.


### Восстановление при рестарте {#восстановление-при-рестарте}

State уже на диске — **мгновенный рестарт**. Это главное преимущество перед in-memory подходом.

Для защиты от потери диска:

-   **Changelog topic** — писать каждое изменение state в компактированный топик. При потере диска — восстановить store из changelog.
-   **Backup/replication** — если store поддерживает (например, LMDB snapshots).


### Gotchas {#gotchas}

-   **Привязка к диску** — state локален для конкретного инстанса. При rebalance (партиция уходит на другой инстанс) state нужно перестроить. Kafka Streams решает это через standby replicas (`num.standby.replicas`).
-   **Disk IOPS** — RocksDB генерирует write amplification из-за LSM compaction. На SSD это нормально, на HDD — проблема.
-   **GC pressure** — для JVM-приложений: RocksDB через JNI не создаёт GC pressure (данные off-heap). BadgerDB в Go — тоже хорошо. SQLite через JDBC — зависит от размера результатов.
-   **Размер на диске** — LSM-tree stores (RocksDB, BadgerDB) могут использовать в 2--10x больше диска, чем логический размер данных, из-за compaction.


### Когда использовать {#когда-использовать}

-   State не помещается в память
-   Нужен быстрый рестарт без bootstrap из Kafka
-   Высокий throughput (embedded store быстрее сетевых БД)
-   Готовы управлять lifecycle store вручную (compaction, backup)


## Подход 4: Repartitioning: промежуточный топик {#подход-4-repartitioning-промежуточный-топик}


### Как работает {#как-работает}

Если два топика партиционированы по-разному (разные ключи или разное количество партиций), прямой partition-local join невозможен. Решение: **produce** события из одного (или обоих) топиков в промежуточный топик, партиционированный по join key.

```text
Topic A (user_id, 12 parts)
  ──► re-key by order_id
  ──► Intermediate A' (order_id, 8 parts)

Topic B (order_id, 8 parts)
  ──► already correct

A' + Topic B → partition-local join (подход 1/3)
```

Это аналог `KStream#repartition()` из Kafka Streams, но вручную ([Kafka Streams Co-Partitioning Requirements Illustrated](https://medium.com/publicis-sapient-france/kafka-streams-co-partitioning-requirements-illustrated-2033f686b19c)).


### Реализация {#реализация}

1.  Consumer читает Topic A
2.  Для каждого события извлекает join key из value
3.  Producer отправляет событие в промежуточный топик с `key=join_key` (Kafka default partitioner обеспечит hash-based routing)
4.  Промежуточный топик имеет то же количество партиций, что и Topic B
5.  Второй consumer читает промежуточный топик + Topic B и делает partition-local join


### Семантики {#семантики}

Repartitioning добавляет **ещё один hop** через Kafka. Для exactly-once нужны Kafka transactions на этапе re-key:

```text
producer.beginTransaction()
producer.send(rekeyed_record_to_intermediate)
producer.sendOffsetsToTransaction(source_offsets, consumerGroupId)
producer.commitTransaction()
```


### Gotchas {#gotchas}

-   **Двойная задержка** — событие проходит через два топика (оригинальный + промежуточный) перед join-ом
-   **Дополнительный storage** — промежуточный топик хранит копию данных
-   **Ordering** — при re-key порядок сообщений меняется (разные ключи → разные партиции → разный порядок)
-   **Exactly-once overhead** — транзакции добавляют задержку и снижают throughput (~20--30%)


### Когда использовать {#когда-использовать}

-   Топики имеют разные ключи партиционирования и нельзя поменять (producer-ы чужие)
-   Топики имеют разное количество партиций и нельзя пересоздать
-   Нужен partition-local join для горизонтального масштабирования


## Подход 5: Database-backed join {#подход-5-database-backed-join}


### Как работает {#как-работает}

Оба consumer-а пишут события в общую БД (PostgreSQL, Redis, etc.). Join выполняется SQL-запросом или get-by-key.

```text
Topic A ──► Consumer A ──► INSERT INTO events_a (key, payload, ts)
Topic B ──► Consumer B ──► INSERT INTO events_b (key, payload, ts)

SELECT a.*, b.*
FROM events_a a JOIN events_b b ON a.key = b.key
WHERE ...
```

Формально это «внешняя зависимость», но на практике — самый распространённый подход для сервисов, у которых уже есть PostgreSQL или Redis.


### Варианты БД {#варианты-бд}


#### PostgreSQL {#postgresql}

-   SQL join — любой сложности (inner, left, window functions)
-   UPSERT (`ON CONFLICT DO UPDATE`) — идемпотентная запись
-   Индексы по join key — быстрый lookup
-   LISTEN/NOTIFY или polling — для оповещения о готовности join-а
-   **Минус**: задержка на запись + чтение; при высоком throughput может стать бутылочным горлышком


#### Redis {#redis}

-   `HSET` / `HGET` — быстрый key-value lookup
-   `MULTI/EXEC` — атомарная запись обеих сторон
-   TTL — автоматический expiry неспаренных событий (аналог windowed join)
-   Pub/Sub — уведомление о готовности join-а
-   **Минус**: ограничен размером RAM; нет SQL для сложных join-ов


### Семантики {#семантики}

**At-least-once**: consumer пишет в БД, затем commit offset. При рестарте — повторные записи; БД должна обрабатывать идемпотентно (`UPSERT`, `SET`).

**Exactly-once**: сложно, потому что Kafka offset commit и запись в БД — **две разные системы** (нет distributed transaction). Варианты:

-   **Outbox pattern**: запись в БД + offset в ту же БД-транзакцию. Consumer при старте читает offset из БД, не из Kafka.
-   **Idempotent writes**: допустить at-least-once, но сделать записи идемпотентными (by message ID/offset).


### Восстановление при рестарте {#восстановление-при-рестарте}

State в БД — **переживает рестарт**. Consumer просто продолжает с последнего committed offset.

При потере БД — стандартное восстановление из backup. Данные в Kafka (retention) позволяют перечитать и восстановить.


### Gotchas {#gotchas}

-   **Сетевая задержка** — каждое событие требует round-trip до БД. Batching помогает (`INSERT ... VALUES (...), (...), ...`), но добавляет latency.
-   **Давление на БД** — при высоком throughput БД может не справиться. Нужно мониторить connections, lock contention, WAL size.
-   **Consistency** — между записью в БД и commit offset-а есть окно, в котором crash может привести к inconsistency. Outbox pattern решает, но усложняет.
-   **Масштабирование** — БД становится единой точкой отказа и бутылочным горлышком. В отличие от partition-local подходов, не масштабируется горизонтально (без шардирования).


### Когда использовать {#когда-использовать}

-   У сервиса уже есть PostgreSQL/Redis
-   Join сложный (multi-way, conditional, aggregation) — проще написать SQL
-   Throughput умеренный (тысячи, не миллионы events/sec)
-   Нужна долговременная история joined-данных (не только streaming)
-   Готовы к операционной нагрузке на БД


## Сводная таблица подходов {#сводная-таблица-подходов}

| Подход               | Память/Диск | Рестарт             | Co-partition нужен?  | Сложность | Best for                       |
|----------------------|-------------|---------------------|----------------------|-----------|--------------------------------|
| **In-memory**        | RAM         | Потеря state        | Да                   | Низкая    | Простые join-ы, малый state    |
| **Compacted lookup** | RAM         | Bootstrap           | Нет                  | Низкая    | Обогащение справочником        |
| **Embedded store**   | Диск        | Мгновенный          | Да                   | Средняя   | Большой state, быстрый рестарт |
| **Repartitioning**   | Kafka       | N/A (stateless hop) | Создаёт co-partition | Средняя   | Разное партиционирование       |
| **Database-backed**  | Внешняя БД  | Мгновенный          | Нет                  | Высокая   | Сложные join-ы, уже есть БД    |


## Худший случай: join key в теле сообщения, топологии не совпадают {#худший-случай-join-key-в-теле-сообщения-топологии-не-совпадают}

Отдельно стоит рассмотреть ситуацию, когда два топика не просто имеют разное количество партиций, а **полностью различную топологию**: разные Kafka-ключи, разное количество партиций, и при этом join key **не является Kafka-ключом ни в одном из топиков** — он лежит в теле (payload) сообщения.


### Пример {#пример}

```text
Topic A: "orders" (key=order_id, 12 partitions)
  body: { "order_id": "ORD-123", "items": [...], "payment_ref": "PAY-456" }

Topic B: "payments" (key=payment_id, 8 partitions)
  body: { "payment_id": "PAY-456", "amount": 1500, "status": "confirmed" }

Join condition: A.body.payment_ref == B.key (или B.body.payment_id)
```

Kafka-ключ в топике A — `order_id`, в топике B — `payment_id`. Join нужен по `payment_ref`, который лежит **в теле** сообщения A. Co-partitioning невозможен в принципе — ключи даже семантически разные.


### Почему это сложнее стандартного join {#почему-это-сложнее-стандартного-join}

1.  **Partition-local join невозможен** — события с одинаковым `payment_ref` / `payment_id` лежат в произвольных партициях разных топиков. Consumer, читающий партицию 0 обоих топиков, не увидит обе стороны join-а.
2.  **Join key нужно извлекать из payload** — десериализация обязательна для каждого сообщения ещё до того, как решим, что с ним делать.
3.  **Нельзя просто подписаться на оба топика** — даже если consumer читает все партиции обоих топиков, при горизонтальном масштабировании (несколько инстансов) каждый инстанс видит только часть партиций, и join рассыпается.


### Какие подходы работают {#какие-подходы-работают}

Все подходы из предыдущих разделов применимы, но с нюансами:


#### Вариант A: Repartitioning по join key из body {#вариант-a-repartitioning-по-join-key-из-body}

Применяем [Подход 4](#подход-4-repartitioning-промежуточный-топик), но join key **извлекаем из body** перед re-key. Если `B.key =` join_key= — repartitioning нужен только для A. Если join key в теле обоих — repartition оба.

```text
Topic A (key=order_id)
  ──► deserialize body, extract payment_ref
  ──► produce to A' (key=payment_ref, 8 parts)

Topic B (key=payment_id)
  ──► уже partitioned by payment_id, 8 parts

A' + Topic B → partition-local join (подход 1/3)
```

Специфика: десериализация каждого сообщения **обязательна** на этапе repartitioning. Если join key глубоко в nested JSON / protobuf — это дорого и делается дважды (при re-key + при join).


#### Вариант B: Глобальный буфер (broadcast) {#вариант-b-глобальный-буфер--broadcast}

Применяем [Подход 2](#подход-2-compacted-topic-как-lookup-table) — один из топиков читается **целиком** каждым инстансом (`consumer.assign()` вместо `subscribe()`, аналог `GlobalKTable`). Из тела извлекается join key → строится `Map<join_key, Event>`. Второй топик стримится и делает lookup.

Специфика: не требует co-partitioning; каждый инстанс хранит **полную копию** — O(N) памяти. Не подходит, если «справочный» топик большой.


#### Вариант C: Database-backed join {#вариант-c-database-backed-join}

Применяем [Подход 5](#подход-5-database-backed-join) — оба consumer-а десериализуют payload, извлекают join key и пишут в БД с **индексом по join key**:

```sql
INSERT INTO orders (order_id, payment_ref, payload, ts)
VALUES ('ORD-123', 'PAY-456', '...', now())
ON CONFLICT (order_id) DO UPDATE SET payload = EXCLUDED.payload;

-- Join по extracted key:
SELECT o.*, p.* FROM orders o
JOIN payments p ON o.payment_ref = p.payment_id;
```

Специфика: самый простой вариант, если БД уже есть. SQL даёт гибкость для сложной join-логики.


#### Вариант D: Correlation Identifier {#вариант-d-correlation-identifier}

Паттерн [Correlation Identifier](https://www.enterpriseintegrationpatterns.com/patterns/messaging/CorrelationIdentifier.html) из Enterprise Integration Patterns. Consumer хранит `Map<join_key, PendingRequest>`, извлекая join key из тела обоих топиков. По сути — [Подход 1](#подход-1-client-side-join-с-in-memory-store), где ключом HashMap служит extracted field, а не Kafka key. Подходит для асимметричных join-ов (поток A инициирует, B отвечает).


### Какие подходы НЕ работают {#какие-подходы-не-работают}

-   **Partition-local join без repartitioning** (подходы 1 и 3 «в лоб») — join key в произвольных партициях, partition-local state не поможет
-   **Простой `subscribe()` на оба топика** — при масштабировании каждый инстанс видит только часть данных, join key может быть разделён между инстансами


### Сводка по вариантам для случая «join key в теле» {#сводка-по-вариантам-для-случая-join-key-в-теле}

| Вариант                 | Repartitioning      | Память на инстанс        | Масштабируемость              | Задержка                  |
|-------------------------|---------------------|--------------------------|-------------------------------|---------------------------|
| **A: Repartitioning**   | Да (1 или 2 топика) | Только join state        | Горизонтальная                | +1-2 Kafka hop            |
| **B: Глобальный буфер** | Нет                 | Полная копия справочника | Вертикальная (RAM-bound)      | Минимальная               |
| **C: Database-backed**  | Нет                 | Минимальная              | Зависит от БД                 | Сетевая задержка          |
| **D: Correlation ID**   | Нет                 | Map pending requests     | Горизонтальная (с оговорками) | Зависит от второго топика |

Выбор зависит от:

-   **Размер «справочного» топика** — помещается в RAM → вариант B; нет → вариант A или C
-   **Throughput** — высокий → вариант A (partition-local после repartitioning); умеренный → вариант C
-   **Уже есть БД** → вариант C — минимум кода
-   **Асимметричный join** (один инициирует, другой отвечает) → вариант D


## Left/outer join: emit при отсутствии пары {#left-outer-join-emit-при-отсутствии-пары}

Все подходы выше реализуют **inner join** — результат появляется только когда обе стороны пришли. Но часто нужен left/outer join: «показать заказ, даже если оплата не пришла» или «обогатить событие данными из справочника, но не терять событие при отсутствии справочной записи».


### Семантика {#семантика}

| Тип join              | Результат                                                        | Пример                               |
|-----------------------|------------------------------------------------------------------|--------------------------------------|
| **Inner join**        | Только matched пары                                              | Заказ + оплата                       |
| **Left join**         | Все события левого топика, правая сторона = null если не найдена | Заказ + оплата (или `payment=null`)  |
| **Outer (full) join** | Все события обоих топиков, `null` с пропущенной стороны          | Заказ без оплаты + оплата без заказа |


### Проблема: когда emit-ить неспаренное событие? {#проблема-когда-emit-ить-неспаренное-событие}

В inner join ответ очевиден — при match. В left/outer join нужно решить: **сколько ждать** вторую сторону, прежде чем emit-ить partial result с `null`?

Варианты:


#### Timeout-based emit {#timeout-based-emit}

Самый распространённый подход. Событие из левого топика ждёт пару N секунд/минут. Если за это время match не произошёл — emit с `payment=null`.

```text
Order("ORD-123", payment_ref="PAY-456") поступает в t=0
  → insert в буфер, запустить таймер(5 мин)

Если за 5 мин Payment("PAY-456") не пришёл:
  → emit { order: "ORD-123", payment: null }
  → удалить из буфера

Если Payment пришёл в t=3 мин:
  → отменить таймер
  → emit { order: "ORD-123", payment: {...} }
```

Реализация с `moka`: eviction listener — это и есть left join emit. Eviction по TTL = «пара не пришла»:

```rust
let buffer: Cache<String, Pending> = Cache::builder()
    .time_to_live(Duration::from_secs(300))
    .async_eviction_listener(|key, value, cause| {
        Box::pin(async move {
            if matches!(cause, RemovalCause::Expired) {
                // Left join: emit с null-стороной
                match value {
                    Pending::HasOrder(order) => {
                        emit_left_join(&producer, &order, None).await;
                    }
                    Pending::HasPayment(payment) => {
                        // Для full outer join
                        emit_left_join_payment(&producer, None, &payment).await;
                    }
                }
            }
        })
    })
    .build();
```


#### Watermark-based emit {#watermark-based-emit}

Вместо wall-clock таймера — ориентироваться на event time. Когда watermark (минимальный timestamp среди всех потребляемых партиций) превышает `event_time + grace_period` — событие считается «не дождавшимся пары».

Преимущества: корректно работает при replay и catch-up (processing time может сильно отличаться от event time). Сложнее в реализации: нужно отслеживать watermark по всем партициям обоих топиков.


#### Completion signal {#completion-signal}

Для некоторых use case-ов вторая сторона **гарантированно придёт или явно откажет**. Например, payment gateway отправляет либо `status=confirmed`, либо `status=declined`. В этом случае timeout не нужен — ждём явный сигнал.


### Left join и idempotency {#left-join-и-idempotency}

Проблема: timeout сработал, emit-или `order + null`. Через секунду пришёл payment. Что делать?

Варианты:

-   **Ignore late match** — payment пришёл после timeout, мы его выбрасываем. Простейший вариант, но данные теряются.
-   **Emit correction** — emit второе событие `order + payment` с флагом `corrected=true`. Downstream должен уметь обновлять ранее выданный результат (upsert по `order_id`).
-   **Tombstone + re-emit** — удалить предыдущий partial result (tombstone в выходной топик), затем emit полный. Работает, если выходной топик compacted.

На практике чаще всего используют **emit correction** — это проще, чем управлять tombstone-ами, и downstream обычно уже умеет upsert.


### Left join в дереве решений {#left-join-в-дереве-решений}

Left/outer join **не меняет** выбор подхода (1--5). Он меняет **логику emit-а** внутри выбранного подхода: вместо «emit при match, discard при timeout» — «emit при match ИЛИ при timeout (с null)».


## One-to-many (1:N) join: один заказ — N позиций {#one-to-many--1-n--join-один-заказ-n-позиций}

Стандартный join предполагает 1:1 — одному заказу соответствует одна оплата. Но часто соотношение 1:N: один заказ содержит N позиций (line items), одна отправка включает N посылок, один пользователь имеет N адресов.


### Проблема: когда emit-ить? {#проблема-когда-emit-ить}

В 1:1 join всё просто: пришли обе стороны → emit. В 1:N: пришла «единичная» сторона (заказ) и первая из N позиций. Ждать ли остальные? Сколько их?

```text
Topic A: orders
  { "order_id": "ORD-1", "line_count": 3 }

Topic B: line_items
  { "order_id": "ORD-1", "line_num": 1, "product": "laptop" }
  { "order_id": "ORD-1", "line_num": 2, "product": "mouse" }
  { "order_id": "ORD-1", "line_num": 3, "product": "keyboard" }
```

Варианты стратегии:


#### Eager emit (emit на каждый match) {#eager-emit--emit-на-каждый-match}

Каждая позиция, найдя пару в буфере, emit-ит joined-результат. Для одного заказа будет N выходных событий.

```text
emit: { order: "ORD-1", item: "laptop" }
emit: { order: "ORD-1", item: "mouse" }
emit: { order: "ORD-1", item: "keyboard" }
```

Плюсы: минимальная задержка, простая логика (ничего не буферизуем на стороне N).
Минусы: downstream получает N событий вместо одного; если нужна агрегация (полная стоимость заказа) — downstream делает её сам.


#### Count-based collect (известное N) {#count-based-collect--известное-n}

Если «единичная» сторона содержит `line_count` (или N известно заранее), можно собирать все N позиций в буфере и emit-ить одно событие с полным набором:

```rust
#[derive(Clone)]
struct PendingOrder {
    order: Order,
    expected: usize,
    items: Vec<LineItem>,
}

async fn try_join_item(
    buf: &JoinBuffer,
    producer: &FutureProducer,
    item: LineItem,
) {
    let key = item.order_id.clone();
    if let Some(mut pending) = buf.remove(&key).await {
        pending.items.push(item);
        if pending.items.len() == pending.expected {
            // Все позиции собраны — emit полный заказ
            emit_complete_order(producer, &pending).await;
        } else {
            // Ещё ждём — вернуть в буфер
            buf.insert(key, pending).await;
        }
    }
    // Если заказ ещё не пришёл — буферизовать item отдельно
}
```

Плюсы: один output event с полными данными.
Минусы: нужно знать N заранее; если одна из N позиций потеряется — заказ «зависнет» в буфере навсегда (нужен timeout).


#### Timeout-based collect (неизвестное N) {#timeout-based-collect--неизвестное-n}

N неизвестно или может меняться. Собираем позиции в буфере, emit-им по таймауту — «всё, что собрали за T секунд, считаем полным набором».

```text
t=0: Order("ORD-1") → create buffer entry, start timer(30s)
t=1: LineItem(line=1) → append to buffer
t=3: LineItem(line=2) → append to buffer
t=8: LineItem(line=3) → append to buffer
t=30: timer fired → emit { order: "ORD-1", items: [1, 2, 3] }
```

Плюсы: не нужно знать N; устойчив к потере отдельных позиций (emit то, что есть).
Минусы: задержка = timeout; если позиция придёт после timeout — потеряна (или нужен correction, как в left join).


#### Completion event {#completion-event}

Продюсер отправляет явное событие «конец группы» (`type=order_complete`). Collector ждёт именно его:

```text
LineItem(order="ORD-1", line=1)
LineItem(order="ORD-1", line=2)
LineItem(order="ORD-1", line=3)
OrderComplete(order="ORD-1")  ← сигнал: все позиции отправлены
```

Плюсы: точный момент emit-а без timeout.
Минусы: требует кооперации с продюсером; completion event может потеряться (нужен fallback timeout).


### Выбор стратегии {#выбор-стратегии}

| Стратегия            | N известно? | Задержка      | Полнота данных | Сложность |
|----------------------|-------------|---------------|----------------|-----------|
| **Eager emit**       | Неважно     | Минимальная   | Per-item       | Низкая    |
| **Count-based**      | Да          | До последнего | Полная         | Средняя   |
| **Timeout-based**    | Нет         | = timeout     | Best-effort    | Средняя   |
| **Completion event** | Нет         | До сигнала    | Полная         | Средняя   |

Рекомендации:

-   Downstream умеет агрегировать сам (Kafka Streams, Flink, БД с GROUP BY) → **eager emit**
-   N известно и невелико (&lt; 100) → **count-based** с fallback timeout
-   N неизвестно, eventual consistency допустима → **timeout-based**
-   Контролируете обоих продюсеров → **completion event** с fallback timeout


### 1:N и память {#1-n-и-память}

Для count-based и timeout-based стратегий буфер хранит не одно pending event, а **коллекцию**. Оценка памяти: если средний заказ = 10 позиций по 200 байт, 100K pending заказов = 100K × 10 × 200 = **200 MB**. При больших N или payload — переходить на RocksDB (хранить `Vec<LineItem>` сериализованным в value).

Cuckoo filter по-прежнему работает: ключ фильтра — `order_id`, L2 хранит коллекцию.


## Multi-way join: 3+ топика {#multi-way-join-3-plus-топика}

Все подходы выше рассматривают join двух топиков. На практике нередко нужно объединить 3 и более.


### Каскад попарных join-ов {#каскад-попарных-join-ов}

Самый прямолинейный путь: join(A, B) → промежуточный результат → join(AB, C).

```text
Topic A ──┐
          ├── join(A, B) ──► Intermediate AB ──┐
Topic B ──┘                                    ├── join(AB, C) ──► Result
Topic C ──────────────────────────────────────-┘
```

Каждый этап — один из подходов 1--5. Промежуточный результат может быть Kafka-топиком (добавляет hop и latency) или in-process (если всё в одном consumer).

Проблема: **latency растёт линейно** с количеством join-ов. Для N топиков — N-1 последовательных этапов.


### Star schema: один «центральный» топик {#star-schema-один-центральный-топик}

Если один топик содержит ключи для всех остальных (как fact table в star schema), можно делать N-1 независимых lookup-ов параллельно:

```text
Topic A (fact) ──► Consumer: для каждого event
                     ├── lookup в Table B (by key_b из body)
                     ├── lookup в Table C (by key_c из body)
                     └── emit enriched(A + B + C)
```

Таблицы B, C — compacted topics или embedded stores ([подход 2](#подход-2-compacted-topic-как-lookup-table) / [подход 3](#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite)). Latency = один hop (только чтение fact topic), но память = сумма всех справочников.


### Когда не стоит делать вручную {#когда-не-стоит-делать-вручную}

При 3+ топиках сложность ручного join-а растёт быстро: state management, rebalancing, exactly-once — всё умножается на количество этапов. Это тот случай, когда Kafka Streams (`KStream.join().join()`), Flink SQL или [Arroyo](#обзор-существующих-решений) окупают себя.


## Общие edge cases и рекомендации {#общие-edge-cases-и-рекомендации}


### Late arrivals и out-of-order {#late-arrivals-и-out-of-order}

Kafka гарантирует порядок только **внутри одной партиции** ([Aiven: Does Kafka Preserve Message Ordering?](https://aiven.io/blog/kafka-real-ordering)). Между двумя топиками (и даже между партициями одного топика) порядок не гарантирован.

Что делать:

-   **Буфер с grace period** — держать окно открытым дольше, чем ожидаемый lag
-   **Watermark** — отслеживать минимальный timestamp среди всех потребляемых партиций; считать все события старше watermark «поздними»
-   **Dead letter topic** — опоздавшие события отправлять в отдельный топик для ручного или отложенного разбора


### Rebalancing и state {#rebalancing-и-state}

При rebalance consumer теряет часть партиций и получает новые. Для partition-local state (подходы 1, 3):

-   При `onPartitionsRevoked` — сохранить state (flush в store, commit offsets)
-   При `onPartitionsAssigned` — восстановить state для новых партиций

Рекомендации:

-   `CooperativeStickyAssignor` — минимизирует перемещение партиций
-   `group.instance.id` (static membership) — предотвращает rebalance при коротких рестартах
-   `partition.assignment.strategy=cooperative-sticky` ([Cooperative Rebalancing](https://www.confluent.io/blog/cooperative-rebalancing-in-kafka-streams-consumer-ksqldb/))


### Exactly-once: общий паттерн {#exactly-once-общий-паттерн}

Для read-process-write в Kafka (подходы 1, 3, 4) — Kafka transactions:

1.  `producer.initTransactions()` при старте
2.  `producer.beginTransaction()` перед обработкой batch-а
3.  `producer.send(output_records)` — записать результаты
4.  `producer.sendOffsetsToTransaction(offsets, groupId)` — коммит offset-ов
5.  `producer.commitTransaction()` — атомарный коммит

Consumer на выходном топике должен читать с `isolation.level=read_committed` ([Baeldung: Exactly Once Processing in Kafka with Java](https://www.baeldung.com/kafka-exactly-once)).

Для подхода 5 (database-backed) — outbox pattern или idempotent writes.


## Оптимизация памяти: windowed буфер и вероятностные структуры {#оптимизация-памяти-windowed-буфер-и-вероятностные-структуры}

Ситуация: consumer читает Topic A, извлекает join key из тела и ждёт появления этого ключа в Topic B. Окно ожидания ограничено (например, 4 часа). Как минимизировать потребление памяти?


### Windowed буфер вместо полного хранения {#windowed-буфер-вместо-полного-хранения}

Вместо бесконечного буфера — хранить pending events только в пределах временного окна. Три подхода к eviction:


#### Наивный per-key TTL {#наивный-per-key-ttl}

`HashMap<Key, (Event, Expiry)>` + фоновый поток для периодического сканирования. Проблемы: O(N) scan на каждый tick, lock contention.


#### Timing Wheel (колесо таймеров) {#timing-wheel--колесо-таймеров}

Классическая структура из [Varghese &amp; Lauck 1987](https://blog.acolyer.org/2015/11/23/hashed-and-hierarchical-timing-wheels/). Insert, cancel, expire — O(1) amortized.

```text
Слоты: |0|1|2|3|4|5|6|7|  (tick = 1 минута, 8 слотов = 8 минут)
         ^
     текущий tick

Каждый слот — linked list таймеров, при advance — все в текущем слоте expired.
```

Для 4-часового окна с минутной гранулярностью: 240 слотов. **Hierarchical timing wheel** — несколько уровней с разной гранулярностью. Apache Kafka использует [иерархические timing wheels](https://www.confluent.io/blog/apache-kafka-purgatory-hierarchical-timing-wheels/) для Kafka Purgatory.


#### Time-bucketed HashMap {#time-bucketed-hashmap}

Вместо единой HashMap — разбить буфер на временные bucket-ы. Каждый bucket — отдельная HashMap на 15-минутный интервал. Когда bucket expire — удаляем целиком за O(1).

```text
4-часовое окно, 15-минутные bucket-ы = 16 bucket-ов

Bucket 0: [12:00-12:15) → HashMap{key1: event, key2: event, ...}
Bucket 1: [12:15-12:30) → HashMap{key3: event, ...}
...
Bucket 15: [15:45-16:00) → HashMap{...}

Текущее время: 16:05 → Bucket 0 expired → drop entire HashMap
```

Lookup по ключу — проверить все 16 активных bucket-ов: O(16), каждый HashMap.get — O(1). Компромисс: гранулярность TTL огрублена до размера bucket-а.


### Bloom-фильтры и Cuckoo-фильтры: пропуск 99% событий Topic B {#bloom-фильтры-и-cuckoo-фильтры-пропуск-99-событий-topic-b}

Основная идея: большинство событий в Topic B **не имеют пары** в pending буфере. Вместо lookup в HashMap/RocksDB на каждое событие — вероятностная проверка.

| Свойство              | Bloom filter | Counting Bloom | Cuckoo filter |
|-----------------------|--------------|----------------|---------------|
| Удаление              | Нет          | Да             | Да            |
| Бит/элемент (FPR ~1%) | ~10          | ~30--40        | ~12           |
| Worst-case lookup     | O(k)         | O(k)           | O(1)          |

**Cuckoo filter** ([Fan et al. 2014](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)) — оптимальный выбор для stream join: нативная поддержка удаления (после успешного join ключ убирается из фильтра) при памяти, сопоставимой с Bloom filter.

Числовой пример: 1M pending ключей при FPR ~1%:

-   Cuckoo filter: 1M × 12 бит = **1.5 MB**
-   `HashMap<String, _>` только на ключи: **50--100 MB**

**Когда фильтр НЕ помогает**: если match rate высокий (&gt;30--50% событий Topic B находят пару), фильтр пропускает большинство событий на L2, и overhead на insert/delete в фильтр + false positive lookups **превышает** экономию. Фильтр эффективен, когда pending ключи — малая доля от общего потока Topic B (типично: &lt;5% match rate).


### Двухуровневая архитектура: Cuckoo (L1) + RocksDB (L2) {#двухуровневая-архитектура-cuckoo--l1--plus-rocksdb--l2}

```text
Topic B event ──► Cuckoo filter (L1, RAM)
                    │
                    ├── "нет" → skip (99% событий)
                    │
                    └── "возможно да"
                          │
                          ▼
                        RocksDB (L2, disk)
                          │
                          ├── найден → emit, del L1+L2
                          └── не найден → FP, skip
```

При 1M pending ключей, Topic B 100K events/sec, match rate ~1%:

-   Без фильтра: 100K lookup/sec в RocksDB
-   С cuckoo filter (FPR 1%): 1K real + 1K false positive = 2K lookup/sec — **снижение нагрузки на L2 в 50 раз**

RocksDB сам использует [Bloom filter](https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter) на SST-файлах — это **третий уровень** фильтрации: наш cuckoo (L1) → RocksDB (L2) → bloom в SST (L2.5) → disk read.


### Что хранить в буфере: full event vs. key+offset vs. проекция {#что-хранить-в-буфере-full-event-vs-dot-key-plus-offset-vs-dot-проекция}

| Вариант                          | Размер на 1M events (payload ~1 KB) | Trade-off                                                                     |
|----------------------------------|-------------------------------------|-------------------------------------------------------------------------------|
| **Full event**                   | ~1.1 GB                             | Мгновенный emit, но дорого по RAM                                             |
| **Key + offset**                 | ~88 MB (12× меньше)                 | Нужен re-fetch из Kafka при match (+1--10 ms), не работает с compacted topics |
| **Key + проекция (нужные поля)** | ~136 MB                             | Лучший компромисс, если output-поля известны заранее                          |

Рекомендации:

-   Pending events &lt; 100K, payload &lt; 1 KB → full event (простота)
-   Pending events 100K--10M → проекция или key+offset
-   Payload &gt; 10 KB → key+offset (экономия критична)


### Компактное представление ключей {#компактное-представление-ключей}

Хеширование строковых ключей до фиксированного размера:

| Размер hash | Коллизии при 1M ключей |
|-------------|------------------------|
| 64 бит      | ~1 из 4×10^12          |
| 128 бит     | ~1.5×10^(-26)          |

128-bit hash (SipHash, xxHash128) — безопасный выбор. Экономия: строка ~36 байт → hash 16 байт.


### Комбинированная архитектура для production {#комбинированная-архитектура-для-production}

Собираем всё: 4-часовое окно, 1--5M pending ключей, payload ~1 KB.

```text
Topic A ──► extract join key ──► hash(u64)
              │
              ├── Cuckoo filter (L1, ~7.5 MB)
              └── Time-bucketed RocksDB (L2, disk)
                    key: u64 hash
                    value: projection (~60 байт)
                    16 buckets × 15 мин

Topic B ──► extract key ──► hash(u64)
              │
              ▼
          Cuckoo filter (L1)
              │
              ├── miss → skip (99%)
              └── hit → RocksDB (L2)
                    │
                    ├── found → emit, del L1+L2
                    └── not found → FP, skip

Eviction: каждые 15 мин
  → drop oldest bucket из RocksDB
  → rebuild Cuckoo (или per-bucket filters)
```


#### Оценка ресурсов для 5M pending ключей {#оценка-ресурсов-для-5m-pending-ключей}

| Компонент           | Размер          |
|---------------------|-----------------|
| Cuckoo filter       | ~7.5 MB         |
| RocksDB (on-disk)   | ~400 MB         |
| RocksDB block cache | 64--128 MB RAM  |
| **Итого RAM**       | **~70--136 MB** |
| **Итого Disk**      | **~400 MB**     |

Для сравнения: наивный `HashMap<String, FullEvent>` на 5M entries = **~5.5 GB RAM**.


## Какой подход выбрать: дерево решений {#какой-подход-выбрать-дерево-решений}

Шпаргалка для быстрого выбора подхода на основе характеристик задачи.

```text
Join key — это Kafka key в обоих топиках?
│
├── ДА → Топики co-partitioned?
│         │
│         ├── ДА → State помещается в RAM?
│         │         ├── ДА → Подход 1: In-memory HashMap
│         │         └── НЕТ → Подход 3: Embedded store
│         │
│         └── НЕТ → Можно пересоздать топик?
│                   ├── ДА → Пересоздать, подход 1 или 3
│                   └── НЕТ → Подход 4: Repartitioning
│
└── НЕТ → Join key в теле сообщения (payload)
          │
          ├── Один топик — справочник?
          │   ├── ДА, в RAM → Подход 2: Compacted + HashMap
          │   └── ДА, не в RAM → Подход 2 + embedded store
          │
          ├── Оба топика — потоки событий?
          │   ├── Есть БД → Подход 5: Database-backed
          │   ├── Высокий throughput → Repartitioning
          │   └── Один маленький → Глобальный буфер
          │
          └── Миллионы pending ключей?
              → Cuckoo/BinaryFuse (L1) + RocksDB (L2)

Ортогональные решения:
├── Left/outer join → Timeout/watermark emit
└── 1:N join → Count-based / timeout / completion
```


## Что делает Kafka Streams под капотом {#что-делает-kafka-streams-под-капотом}

Для контекста: Kafka Streams реализует join-ы ровно теми же примитивами:

-   **KStream-KStream join** — два in-memory/RocksDB store (по одному на каждую сторону), windowed, с changelog topics для восстановления. Это [подход 1](#подход-1-client-side-join-с-in-memory-store) + [подход 3](#подход-3-embedded-state-store--rocksdb-badgerdb-sqlite)
-   **KStream-KTable join** — один store для table-стороны, stream-сторона делает lookup. Это [подход 2](#подход-2-compacted-topic-как-lookup-table) с RocksDB вместо HashMap
-   **KStream-GlobalKTable join** — таблица реплицирована на все инстансы (все партиции), не требует co-partitioning. Это [подход 2](#подход-2-compacted-topic-как-lookup-table) в чистом виде
-   **Repartitioning** — автоматическое создание промежуточного топика при несовпадении ключей. Это [подход 4](#подход-4-repartitioning-промежуточный-топик)

Kafka Streams добавляет: автоматический changelog, rebalance-aware state management, standby replicas, exactly-once через Kafka transactions, метрики, fault tolerance. Если нужно всё это — проще использовать Kafka Streams, чем реализовывать вручную. Ручная реализация оправдана когда:

-   Нет JVM (Go, Rust, Python)
-   Нужен минимальный footprint (single binary без фреймворка)
-   Join тривиален и не оправдывает зависимость от Kafka Streams
-   Нужна кастомная логика, которую сложно выразить через DSL Kafka Streams


## Реализация на Rust: rdkafka и экосистема крейтов {#реализация-на-rust-rdkafka-и-экосистема-крейтов}

Rust — один из основных кейсов для ручной реализации join: нет Kafka Streams (JVM-only), нет зрелых stream-processing фреймворков. Крейт [rust-rdkafka](https://github.com/fede1024/rust-rdkafka) (v0.39, librdkafka под капотом) предоставляет полноценный consumer/producer API с интеграцией в tokio.


### rdkafka: потребление из нескольких топиков {#rdkafka-потребление-из-нескольких-топиков}

`StreamConsumer` поддерживает подписку на несколько топиков одним вызовом `subscribe`:

```rust
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::ClientConfig;

let consumer: StreamConsumer = ClientConfig::new()
    .set("group.id", "join-worker")
    .set("bootstrap.servers", "kafka:9092")
    .set("enable.auto.commit", "true")
    .set("auto.commit.interval.ms", "5000")
    .set("enable.auto.offset.store", "false")  // manual store_offset
    .set("auto.offset.reset", "earliest")
    .create()
    .expect("consumer creation failed");

// Один consumer, два топика
consumer.subscribe(&["orders", "payments"])
    .expect("subscribe failed");
```

Метод `recv().await` возвращает `BorrowedMessage`, у которого есть `.topic()` — по нему определяем источник:

```rust
loop {
    match consumer.recv().await {
        Ok(msg) => {
            match msg.topic() {
                "orders" => handle_order(&msg, &state).await,
                "payments" => handle_payment(&msg, &state).await,
                _ => {}
            }
            // store offset только после успешной обработки
            consumer.store_offset_from_message(&msg).unwrap();
        }
        Err(e) => warn!("kafka error: {e}"),
    }
}
```


#### Один consumer vs. два {#один-consumer-vs-dot-два}

| Вариант                                   | Плюсы                                                       | Минусы                                             |
|-------------------------------------------|-------------------------------------------------------------|----------------------------------------------------|
| **Один consumer, два топика**             | Один event loop, нет синхронизации, проще offset management | Медленный топик тормозит быстрый (head-of-line)    |
| **Два consumer-а, по топику**             | Независимый throughput, можно разные `group.id`             | Нужна синхронизация state (`Arc<Mutex>` или канал) |
| **Один consumer + split_partition_queue** | Разделение по партициям без отдельных consumer-ов           | Сложнее управлять, state всё равно общий           |

Для join рекомендация: **один consumer на оба топика**. Это гарантирует, что при rebalance партиции обоих топиков назначаются согласованно (один `group.id`, один assignment). При двух consumer-ах с разными group-ами нет гарантии, что один инстанс получит «парные» партиции.


#### StreamConsumer vs. BaseConsumer {#streamconsumer-vs-dot-baseconsumer}

`StreamConsumer` — async, интегрирован с tokio (дефолтный runtime). Метод `recv()` — cancellation-safe, можно использовать в `tokio::select!`.

`BaseConsumer` — sync, требует ручного `poll()`. Подходит для случаев без async runtime или когда нужен полный контроль над polling loop.

Для join-а `StreamConsumer` предпочтительнее: async позволяет совмещать потребление с HTTP/gRPC, таймерами для eviction, метриками.

**Критическое ограничение**: при использовании `subscribe()` (consumer group protocol), нужно вызывать `recv()` не реже чем раз в `max.poll.interval.ms` (дефолт 300с), иначе librdkafka считает consumer зависшим и вызывает rebalance.


### Полный скетч: windowed join с TTL-буфером {#полный-скетч-windowed-join-с-ttl-буфером}

```rust
use std::sync::Arc;

use moka::future::Cache;
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::message::BorrowedMessage;
use rdkafka::producer::{FutureProducer, FutureRecord};
use rdkafka::{ClientConfig, Message};
use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Deserialize, Clone)]
struct Order {
    order_id: String,
    payment_ref: String,
    items: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct Payment {
    payment_id: String,
    amount: u64,
    status: String,
}

/// Стороны join-а: одна из сторон уже пришла, ждём вторую
#[derive(Debug, Clone)]
enum Pending {
    HasOrder(Order),
    HasPayment(Payment),
}

/// moka::future::Cache с TTL = окно join-а.
/// Ключ — join key (payment_ref / payment_id).
/// При eviction по TTL — событие не нашло пару (можно отправить в DLT).
type JoinBuffer = Cache<String, Pending>;

fn create_consumer(brokers: &str, group: &str) -> StreamConsumer {
    ClientConfig::new()
        .set("group.id", group)
        .set("bootstrap.servers", brokers)
        .set("enable.auto.commit", "true")
        .set("auto.commit.interval.ms", "5000")
        .set("enable.auto.offset.store", "false")
        .set("auto.offset.reset", "earliest")
        .set("session.timeout.ms", "10000")
        .create()
        .expect("consumer creation failed")
}

fn create_producer(brokers: &str) -> FutureProducer {
    ClientConfig::new()
        .set("bootstrap.servers", brokers)
        .set("message.timeout.ms", "5000")
        .create()
        .expect("producer creation failed")
}

#[tokio::main]
async fn main() {
    let consumer = create_consumer("kafka:9092", "join-worker");
    consumer.subscribe(&["orders", "payments"]).unwrap();

    let producer = create_producer("kafka:9092");

    // TTL = 5 минут — окно join-а
    let buffer: JoinBuffer = Cache::builder()
        .time_to_live(Duration::from_secs(300))
        .max_capacity(1_000_000)
        .async_eviction_listener(|key, value, _cause| {
            Box::pin(async move {
                // Не нашли пару — логируем или шлём в DLT
                tracing::warn!(key = %key, "join timeout: unmatched event");
            })
        })
        .build();

    loop {
        match consumer.recv().await {
            Ok(msg) => {
                let payload = match msg.payload() {
                    Some(p) => p,
                    None => continue,
                };
                match msg.topic() {
                    "orders" => {
                        let ok = serde_json::from_slice::<Order>(payload);
                        if let Ok(order) = ok {
                            try_join_order(&buffer, &producer, order).await;
                        }
                    }
                    "payments" => {
                        let ok = serde_json::from_slice::<Payment>(payload);
                        if let Ok(pay) = ok {
                            try_join_payment(&buffer, &producer, pay).await;
                        }
                    }
                    _ => {}
                }
                consumer.store_offset_from_message(&msg).unwrap();
            }
            Err(e) => tracing::warn!("kafka error: {e}"),
        }
    }
}

async fn try_join_order(
    buf: &JoinBuffer,
    producer: &FutureProducer,
    order: Order,
) {
    let key = order.payment_ref.clone();
    match buf.remove(&key).await {
        Some(Pending::HasPayment(payment)) => {
            emit_joined(producer, &order, &payment).await;
        }
        _ => {
            buf.insert(key, Pending::HasOrder(order)).await;
        }
    }
}

async fn try_join_payment(
    buf: &JoinBuffer,
    producer: &FutureProducer,
    payment: Payment,
) {
    let key = payment.payment_id.clone();
    match buf.remove(&key).await {
        Some(Pending::HasOrder(order)) => {
            emit_joined(producer, &order, &payment).await;
        }
        _ => {
            buf.insert(key, Pending::HasPayment(payment)).await;
        }
    }
}

async fn emit_joined(
    producer: &FutureProducer,
    order: &Order,
    payment: &Payment,
) {
    let joined = serde_json::json!({
        "order_id": order.order_id,
        "payment_id": payment.payment_id,
        "amount": payment.amount,
        "status": payment.status,
        "items": order.items,
    });
    let payload = joined.to_string();
    let record = FutureRecord::to("joined-events")
        .key(&order.order_id)
        .payload(&payload);
    if let Err((e, _)) = producer.send(record, Duration::from_secs(5)).await {
        tracing::error!("failed to send joined event: {e}");
    }
}
```


### Ручной commit offset: паттерн at-least-once {#ручной-commit-offset-паттерн-at-least-once}

Ключевой трюк: `enable.auto.commit=true` + `enable.auto.offset.store=false`. Автокоммит работает по таймеру, но коммитит только **явно сохранённые** offset-ы. Вызов `store_offset_from_message(&msg)` помечает offset как готовый к коммиту.

```rust
// НЕ делать: commit на каждое сообщение (медленно, нагрузка на брокер)
// consumer.commit_message(&msg, CommitMode::Async).unwrap();

// Делать: store offset, автокоммит сам отправит batch
consumer.store_offset_from_message(&msg).unwrap();
```

При краше между `store_offset` и автокоммитом — сообщение будет перечитано (at-least-once). Обработка должна быть идемпотентной.

Для **ручного коммита** без автокоммита:

```rust
// enable.auto.commit = false
// Коммитим вручную каждые N сообщений или по таймеру
consumer.commit_message(&msg, CommitMode::Async).unwrap();
// или
consumer.commit_consumer_state(CommitMode::Async).unwrap();
```


### Rebalance callbacks в rdkafka {#rebalance-callbacks-в-rdkafka}

`ConsumerContext` trait позволяет перехватывать rebalance. Это критично для join-а: при потере партиции нужно очистить state для неё.

```rust
use rdkafka::consumer::{ConsumerContext, Rebalance};
use rdkafka::client::ClientContext;

struct JoinContext {
    // ссылка на state для очистки при rebalance
}

impl ClientContext for JoinContext {}

impl ConsumerContext for JoinContext {
    fn pre_rebalance(&self, rebalance: &Rebalance) {
        match rebalance {
            Rebalance::Revoke(tpl) => {
                // Партиции отзываются — flush pending state,
                // commit offsets для этих партиций
                tracing::info!("partitions revoked: {:?}", tpl);
            }
            Rebalance::Assign(tpl) => {
                tracing::info!("partitions assigned: {:?}", tpl);
            }
            Rebalance::Error(err) => {
                tracing::error!("rebalance error: {}", err);
            }
        }
    }

    fn post_rebalance(&self, rebalance: &Rebalance) {
        if let Rebalance::Assign(_tpl) = rebalance {
            // Новые партиции — можно начать bootstrap state
        }
    }

    fn commit_callback(
        &self,
        result: rdkafka::error::KafkaResult<()>,
        offsets: &rdkafka::TopicPartitionList,
    ) {
        if let Err(e) = result {
            tracing::error!("commit failed: {e}, offsets: {:?}", offsets);
        }
    }
}

// Использование:
let context = JoinContext { /* ... */ };
let consumer: StreamConsumer<JoinContext> = ClientConfig::new()
    // ... config ...
    .create_with_context(context)
    .expect("consumer creation failed");
```

**Важно**: `pre_rebalance` и `post_rebalance` вызываются из librdkafka polling thread и должны завершаться быстро. Нельзя делать async I/O внутри — только обновить флаги/счётчики.


### Вариант с RocksDB для state store {#вариант-с-rocksdb-для-state-store}

Если буфер не помещается в RAM или нужен быстрый рестарт — `moka` заменяется на `rocksdb`:

```rust
use rocksdb::{DB, Options};

fn open_state_store(path: &str) -> DB {
    let mut opts = Options::default();
    opts.create_if_missing(true);
    opts.set_max_write_buffer_number(4);
    // TTL через compaction filter — rocksdb сам удалит просроченные
    DB::open(&opts, path).unwrap()
}

/// Запись в store: key = join_key, value = serialized Pending + timestamp
fn put_pending(db: &DB, join_key: &str, pending: &Pending) {
    let value = serde_json::to_vec(pending).unwrap();
    db.put(join_key.as_bytes(), &value).unwrap();
}

/// Lookup + delete (atomic get-and-remove через delete после get)
fn take_pending(db: &DB, join_key: &str) -> Option<Pending> {
    match db.get(join_key.as_bytes()) {
        Ok(Some(bytes)) => {
            db.delete(join_key.as_bytes()).unwrap();
            serde_json::from_slice(&bytes).ok()
        }
        _ => None,
    }
}
```

Для TTL в RocksDB: использовать `compaction_filter` который проверяет timestamp в value и удаляет записи старше окна. Или хранить offset в самом RocksDB и при рестарте — `consumer.seek()` на сохранённый offset.


### Экосистема крейтов {#экосистема-крейтов}

| Крейт                                                                                       | Версия | Назначение                                 |
|---------------------------------------------------------------------------------------------|--------|--------------------------------------------|
| [rdkafka](https://crates.io/crates/rdkafka)                                                 | 0.39   | Kafka consumer/producer, tokio integration |
| [serde](https://crates.io/crates/serde) + [serde_json](https://crates.io/crates/serde_json) | 1.x    | Десериализация JSON payload                |
| [moka](https://crates.io/crates/moka)                                                       | 0.12   | Async TTL-кеш (замена `HashMap` + таймер)  |
| [dashmap](https://crates.io/crates/dashmap)                                                 | 6.x    | Concurrent `HashMap` (без TTL, но быстрее) |
| [rocksdb](https://crates.io/crates/rocksdb)                                                 | 0.24   | Embedded KV store (аналог Kafka Streams)   |
| [tracing](https://crates.io/crates/tracing)                                                 | 0.1    | Structured logging                         |
| [tokio](https://crates.io/crates/tokio)                                                     | 1.x    | Async runtime (`StreamConsumer` default)   |


#### moka vs. dashmap для join-буфера {#moka-vs-dot-dashmap-для-join-буфера}

`moka::future::Cache` — **предпочтительный выбор** для windowed join:

-   Встроенный TTL (`time_to_live`) — автоматический eviction по таймауту, не нужно писать свой reaper
-   `async_eviction_listener` — callback при eviction, можно отправлять в dead letter topic
-   Admission policy (TinyLFU) — при переполнении вытесняет наименее полезные, а не случайные записи
-   Thread-safe, работает с `tokio`

`dashmap` — если TTL не нужен (infinite buffer / lookup table) или нужен raw concurrent `HashMap` с максимальной скоростью. Нет встроенного eviction — нужно реализовывать самому (фоновый tokio task с `retain`).


#### mini-moka vs. moka {#mini-moka-vs-dot-moka}

[mini-moka](https://github.com/moka-rs/mini-moka) — упрощённая версия без async cache, без per-entry expiration, без lock-free итератора. Подходит для sync-контекста, где не нужна `future::Cache`. Для join-а с tokio — использовать полный `moka`.


### Известные ограничения и грабли {#известные-ограничения-и-грабли}

1.  **librdkafka thread model** — rdkafka использует внутренние потоки librdkafka для networking и polling. `StreamConsumer::recv()` безопасен для отмены (cancellation-safe), но `stream()` — нет. В `tokio::select!` использовать `recv()`.

2.  **max.poll.interval.ms** — если обработка сообщения (десериализация + lookup + produce) занимает больше 300с, consumer будет исключён из группы. Для тяжёлой обработки — увеличить таймаут или выносить работу в `tokio::spawn`.

3.  **Порядок сообщений** — при потреблении двух топиков одним consumer-ом порядок между топиками **не гарантирован**. Сообщение из «payments» может прийти раньше соответствующего «orders». Буфер обязателен.

4.  **Rebalance и state** — при rebalance `moka` cache **не знает** про партиции. Если один инстанс получал партицию 0 «orders» и положил pending event в cache, а после rebalance партиция ушла другому инстансу — pending event останется в cache первого инстанса и никогда не будет matched. Для partition-local join нужно вести отдельный state per partition (`HashMap<(topic, partition), Cache>`) и очищать при `Rebalance::Revoke`.

5.  **Backpressure** — `FutureProducer::send` блокирует, если внутренний буфер librdkafka заполнен (`queue.buffering.max.messages`, дефолт 100000). При высоком throughput join-а producer может стать бутылочным горлышком.

6.  **Дубликаты ключей** — в скетче выше `try_join_order` при повторном ордере с тем же `payment_ref` молча перезаписывает pending entry в буфере. Первый ордер теряется. Если дубликаты возможны — нужна стратегия: хранить `Vec<Order>` вместо одного, либо reject с логированием, либо использовать `entry_or_insert` и проверять.

7.  **Graceful shutdown** — скетч не обрабатывает SIGTERM. В production нужно перехватывать сигнал, прекратить потребление, flush pending state (отправить в DLT или changelog), commit offsets:

<!--listend-->

```rust
use tokio::signal;

loop {
    tokio::select! {
        msg = consumer.recv() => {
            // обработка как в скетче выше
        }
        _ = signal::ctrl_c() => {
            tracing::info!("shutting down: flushing pending state");
            // Итерировать buffer, отправить unmatched в DLT
            // consumer.commit_consumer_state(CommitMode::Sync).unwrap();
            break;
        }
    }
}
```


## Обзор существующих решений {#обзор-существующих-решений}

Краткий обзор библиотек и фреймворков для stream join поверх Kafka — с фокусом на Go и Rust.


### Go {#go}


#### [Goka](https://github.com/lovoo/goka) — stream-table join (2.5k stars, активно поддерживается) {#goka-stream-table-join--2-dot-5k-stars-активно-поддерживается}

Самая зрелая Go-библиотека для stateful stream processing. Предоставляет `ctx.Join(table)` (co-partitioned stream-table join по текущему ключу) и `ctx.Lookup(table, key)` (lookup join для произвольного ключа без co-partitioning). State хранится в LevelDB (pluggable). Views — read-only кеш таблицы целиком (аналог GlobalKTable).

Ограничения:

-   **Нет KStream-KStream windowed join** — только stream-table
-   **Нет exactly-once** — at-least-once only
-   Подходит для обогащения (enrichment), но не для двустороннего stream-stream join


#### [franz-go](https://github.com/twmb/franz-go) — лучший Kafka-клиент для Go (2.7k stars) {#franz-go-лучший-kafka-клиент-для-go--2-dot-7k-stars}

Самый полнофункциональный pure-Go Kafka-клиент. Поддерживает транзакции (единственный Go-клиент с EOS), cooperative rebalancing, admin API. **Никаких** абстракций для join — это фундамент, на котором строится ручная логика. На практике большинство Go-команд именно так и делают: franz-go + Redis/RocksDB + ручной join.


#### [gmbyapa/kstream](https://github.com/gmbyapa/kstream) — порт Kafka Streams на Go (30 stars) {#gmbyapa-kstream-порт-kafka-streams-на-go--30-stars}

Ближе всего к Java Kafka Streams по API: KTable-KTable join, KStream-KTable join, KStream-GlobalKTable join, Foreign-Key join. Pluggable state store, заявлена EOS. **Но**: 30 stars, низкая активность — рискованно для production.


#### [Redpanda Connect / Benthos](https://github.com/redpanda-data/connect) — ETL-процессор (8.6k stars) {#redpanda-connect-benthos-etl-процессор--8-dot-6k-stars}

300+ коннекторов, YAML-конфигурация. Join реализуется через [паттерн enrichment](https://docs.redpanda.com/redpanda-connect/cookbooks/joining_streams/): один pipeline пишет в Redis-кеш, другой делает lookup. Не stateful stream processing — скорее программируемый Kafka Connect.


#### Итого по Go {#итого-по-go}

Полноценного аналога Java Kafka Streams с KStream-KStream windowed join и EOS в Go **не существует**. Реальный паттерн: franz-go (или sarama) + ручной state в Redis/RocksDB. Для stream-table join — Goka.


### Rust {#rust}


#### [rust-rdkafka](https://github.com/fede1024/rust-rdkafka) — стандартный Kafka-клиент (1.9k stars) {#rust-rdkafka-стандартный-kafka-клиент--1-dot-9k-stars}

Обёртка над librdkafka с async/tokio интеграцией. Поддерживает транзакции. Никаких stream processing абстракций — фундамент для ручной реализации (подробнее в [разделе выше](#реализация-на-rust-rdkafka-и-экосистема-крейтов)).


#### [Arroyo](https://github.com/ArroyoSystems/arroyo) — stream processing engine (4.8k stars, Cloudflare) {#arroyo-stream-processing-engine--4-dot-8k-stars-cloudflare}

Полноценный движок потоковой обработки на Rust, сравнимый с Apache Flink. SQL-first интерфейс. Поддерживает inner/left/outer/full joins, windowed joins (tumbling, sliding, session), lookup joins. Kafka-native, EOS через транзакции. Заявляет 5× производительность Flink.

Ключевое: Arroyo — это **standalone engine** (деплоится как кластер), а не встраиваемая библиотека. Если нужен полноценный stream-stream windowed join с SQL — лучший вариант в Rust-экосистеме.


#### [Fluvio](https://github.com/infinyon/fluvio) — Rust-native стриминговая платформа (5.2k stars) {#fluvio-rust-native-стриминговая-платформа--5-dot-2k-stars}

**Замена Kafka**, а не клиент для Kafka. Свой брокер + Stateful DataFlow (SDF) с SQL joins, GROUP BY, агрегации через WASM SmartModules. Если вы привязаны к Kafka — Fluvio не подходит напрямую (хотя есть коннекторы).


#### [Callysto](https://github.com/vertexclique/callysto) — порт Kafka Streams на Rust (160 stars, stale) {#callysto-порт-kafka-streams-на-rust--160-stars-stale}

Попытка создать Kafka Streams-подобный фреймворк для Rust. Последний релиз — октябрь 2022. Фактически заброшен. Не рекомендуется.


### Сводная таблица {#сводная-таблица}

| Библиотека           | Язык | Stars | Join-ы         | State store  | EOS | Статус               |
|----------------------|------|-------|----------------|--------------|-----|----------------------|
| **Goka**             | Go   | 2.5k  | Stream-table   | LevelDB      | Нет | Активен              |
| **franz-go**         | Go   | 2.7k  | Нет (клиент)   | —            | Да  | Активен              |
| **gmbyapa/kstream**  | Go   | 30    | KTable/KStream | Pluggable KV | Да  | Низкая активность    |
| **Redpanda Connect** | Go   | 8.6k  | Enrichment     | External     | Нет | Активен              |
| **Arroyo**           | Rust | 4.8k  | Full SQL joins | Built-in     | Да  | Активен (Cloudflare) |
| **Fluvio**           | Rust | 5.2k  | SQL (SDF)      | Built-in     | Да  | Активен              |
| **rdkafka**          | Rust | 1.9k  | Нет (клиент)   | —            | Да  | Активен              |
| **Callysto**         | Rust | 160   | Неясно         | —            | —   | Заброшен             |


### Вывод {#вывод}

Для **Go с Kafka joins**: зрелого решения нет. Goka покрывает stream-table, для stream-stream — ручная реализация на franz-go + хранилище состояния.

Для **Rust с Kafka joins**: Arroyo — если готовы к standalone engine. Для встраиваемой библиотеки — rdkafka + ручная логика (moka/RocksDB для state, cuckoo filter для оптимизации, как описано в [разделе оптимизации](#оптимизация-памяти-windowed-буфер-и-вероятностные-структуры)).
