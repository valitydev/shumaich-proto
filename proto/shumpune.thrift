include 'base.thrift'

namespace java com.rbkmoney.damsel.shumpune
namespace erlang shumpune

typedef string PlanID
typedef i64 BatchID
typedef string AccountID
typedef string SpanID
typedef string ParentID
typedef string TraceID

/**
* Структура данных, описывающая свойства счета:
* id - номер аккаунта, передаётся клиентом
* currency_sym_code - символьный код валюты (неизменяем после создания счета)
* description - описания (неизменяемо после создания счета)
*
* У каждого счёта должна быть сериализованная история, то есть наблюдаемая любым клиентом в определённый момент времени
* последовательность событий в истории счёта должна быть идентична.
*/
struct Account {
    1: required AccountID id
    2: required base.CurrencySymbolicCode currency_symbolic_code
}

/**
* Структура данных, описывающая свойства счета:
* id - номер сета (генерируется аккаунтером)
* own_amount - собственные средства (объём средств на счёте с учётом только подтвержденных операций)
* max_available_amount - максимально возможные доступные средства
* min_available_amount - минимально возможные доступные средства
*   Где минимально возможные доступные средства - это объем средств с учетом подтвержденных и не подтвержденных
*   операций в определённый момент времени в предположении, что все планы с батчами, где баланс этого счёта изменяется в
*   отрицательную сторону, подтверждены, а планы, где баланс изменяется в положительную сторону, соответственно, отменены.
*   Для максимального значения действует обратное условие.
* clock - время подсчета баланса
*
* У каждого счёта должна быть сериализованная история, то есть наблюдаемая любым клиентом в определённый момент времени
* последовательность событий в истории счёта должна быть идентична.
*/
struct Balance {
    1: required AccountID id
    2: required base.Amount own_amount
    3: required base.Amount max_available_amount
    4: required base.Amount min_available_amount
    5: required Clock clock
}

/**
*  Описывает одну проводку в системе (перевод средств с одного счета на другой):
*  from_account - аккаунт, с которого производится списание
*  to_account - аккаунт, на который производится зачисление
*  amount - объем переводимых средств (не может быть отрицательным)
*  currency_sym_code - код валюты
*  description - описание проводки
*/
struct Posting {
    1: required Account from_account
    2: required Account to_account
    3: required base.Amount amount
    4: required base.CurrencySymbolicCode currency_symbolic_code
    5: required string description
}

/**
* Описывает батч - набор проводок, служит единицей атомарности операций в системе:
* id -  идентификатор набора, уникален в пределах плана
* postings - набор проводок
*/
struct PostingBatch {
    1: required BatchID id
    2: required list<Posting> postings
}

/**
 * План проводок, состоит из набора батчей, который можно пополнить, подтвердить или отменить:
 * id - идентификатор плана, уникален в рамках системы
 * batch_list - набор батчей, связанный с данным планом
 * creation_time - логическое время, к которому привязана транзакция
*/
struct PostingPlan {
    1: required PlanID id
    2: required list<PostingBatch> batch_list
    3: optional base.Timestamp creation_time
}

/**
* Описывает единицу пополнения плана:
* id - id плана, к которому применяется данное изменение
* batch - набор проводок, который нужно добавить в план
* creation_time - логическое время, к которому привязана транзакция
*/
struct PostingPlanChange {
   1: required PlanID id
   2: required PostingBatch batch
   3: optional base.Timestamp creation_time
}

/**
* Плоская структура, описывающая операцию. Используется для записи в Kafka
*/
struct OperationLog {
    1:  required PlanID plan_id
    2:  required BatchID batch_id
    3:  required OperationType operation_type
    4:  required Account account
    5:  required base.Amount amount_with_sign
    6:  required base.CurrencySymbolicCode currency_symbolic_code
    7:  required string description
    8:  required i64 sequence
    9:  required i64 total
    10: required i64 batch_hash
    11: required ValidationStatus validation_status
    12: required i64 operation_time_ms
    13: optional SpanID span_id
    14: optional ParentID parent_id
    15: optional TraceID trace_id
}

/**
* Структура, позволяющая установить причинно-следственную связь операций внутри сервиса
**/
union Clock {
    // для новых операций
    1: VectorClock vector
    // для старых операций, для обратной совместимости. Не рекоммендуется к использованию.
    2: LatestClock latest
}

/**
 * https://en.wikipedia.org/wiki/Vector_clock
 **/
struct VectorClock {
    1: required base.Opaque state
}

struct LatestClock {
}

exception AccountNotFound {
    1: required AccountID account_id
}

exception PlanNotFound {
    1: required PlanID plan_id
}

/**
* Возникает в случае, если переданы некорректные параметры в одной или нескольких проводках,
* либо проводки финальной операции не совпадают с холдом.
*/
exception InvalidPostingParams {
    1: required map<Posting, string> wrong_postings
}

/**
* Исключение, говорящее о том, что сервис ещё не успел синхронизироваться до переданного Clock.
* Необходимо повторить запрос.
**/
exception NotReady {}

/**
* Требования к клиентам сервиса:
* 1) В случае неудачной попытки запроса по любой причине, кроме InvalidPostingParams, запрос должен быть повторён.
* 2) В рамках одного плана запросы должны быть последовательны, после Commit/Rollback не может быть Hold
**/
service Accounter {

    /**
    * Функция для формирования плана для будущего коммита. Может использоваться как для создания, так и для дополнения
    * существующего плана.
    * В случае дополнения плана необходимо передать clock предыдущего холда.
    * В случае, если в плане будет указан не существующий аккаунт - аккаунт будет создан.
    **/
    Clock Hold(1: PostingPlanChange plan_change, 2: Clock clock) throws (
        1: InvalidPostingParams e1
    )

    /**
    * Функция для подтверждения сформированного ранее плана.
    * Проводки в plan должны совпадать с проводками, сформированными на этапе вызовов Hold.
    * clock - значение, которое было возвращено методом Hold
    * После успешного коммита план будет считаться не существовавшим.
    **/
    Clock CommitPlan(1: PostingPlan plan, 2: Clock clock) throws (
        1: InvalidPostingParams e1,
        2: NotReady e3
    )

    /**
    * Функция для отмены сформированного ранее плана.
    * Проводки в plan должны совпадать с проводками, сформированными на этапе вызовов Hold.
    * clock - значение, которое было возвращено методом Hold
    * После успешного роллбэка план будет считаться не существовавшим.
    **/
    Clock RollbackPlan(1: PostingPlan plan, 2: Clock clock) throws (
        1: InvalidPostingParams e1,
        2: NotReady e3
    )

    /**
    * Получение баланса аккаунта.
    * clock - время операции, после которой хотелось бы узнать баланс.
    **/
    Balance GetBalanceByID(1: AccountID id, 2: Clock clock) throws (
        1: AccountNotFound e1,
        2: NotReady e2
    )

    /**
    * Clock - время последней известной операции по этому аккаунту.
    **/
    Account GetAccountByID(1: AccountID id, 2: Clock clock) throws (
        1: AccountNotFound e1,
        2: NotReady e2
    )
}

enum OperationType {
    HOLD
    COMMIT
    ROLLBACK
}

enum ValidationStatus {
    HOLD_NOT_EXIST
}

struct MigrationPostingPlan {
    1: required PlanID plan_id
    2: required BatchID batch_id
    3: required AccountID account_from_id
    4: required AccountID account_to_id
    5: required base.Amount amount
    6: required base.CurrencySymbolicCode currency_symbolic_code
    7: required string description
    8: required base.Timestamp creation_time
    9: required OperationType operation
}

service MigrationHelper {
    void migratePostingPlans(1: list<MigrationPostingPlan> postings)
    void migrateAccounts(1: list<Account> accountList)
}
