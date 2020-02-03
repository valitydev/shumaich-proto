include 'base.thrift'

namespace java com.rbkmoney.damsel.shumpune
namespace erlang shumpune

typedef string PlanID
typedef string OperationID
typedef i64 BatchID
typedef i64 AccountID

/**
* Структура данных, описывающая свойства счета:
* id - номер аккаунта, передаётся клиентом
* currency_sym_code - символьный код валюты (неизменяем после создания счета)
* description - описания (неизменяемо после создания счета)
* creation_time - время создания аккаунта
*
*У каждого счёта должна быть сериализованная история, то есть наблюдаемая любым клиентом в определённый момент времени
* последовательность событий в истории счёта должна быть идентична.
*/
struct Account {
    1: required AccountID id
    2: required base.CurrencySymbolicCode currency_sym_code
    3: optional string description // нужно ли?
    4: optional base.Timestamp creation_time // нужно ли?
}

/**
* Структура данных, описывающая свойства счета:
* id - номер сета (генерируется аккаунтером)
* own_amount - собственные средства (объём средств на счёте с учётом только подтвержденных операций)
* max_available_amount - максимально возможные доступные средства
* min_available_amount - минимально возможные доступные средства
* Где минимально возможные доступные средства - это объем средств с учетом подтвержденных и не подтвержденных
* операций в определённый момент времени в предположении, что все планы с батчами, где баланс этого счёта изменяется в
* отрицательную сторону, подтверждены, а планы, где баланс изменяется в положительную сторону,
* соответственно, отменены.
* Для максимального значения действует обратное условие.
* state - время подсчета баланса
*У каждого счёта должна быть сериализованная история, то есть наблюдаемая любым клиентом в определённый момент времени
* последовательность событий в истории счёта должна быть идентична.
*/
struct Balance {
    1: required AccountID id
    2: required base.Amount own_amount
    3: required base.Amount max_available_amount
    4: required base.Amount min_available_amount
    5: required ClockState state // нужно ли?
}

/**
*  Описывает одну проводку в системе (перевод спедств с одного счета на другой):
*  from_acc - аккаунт, с которого производится списание
*  to_acc - аккаунт, на который производится зачисление
*  amount - объем переводимых средств (не может быть отрицательным)
*  description - описание проводки
*/
struct Posting {
    1: required Account from_acc
    2: required Account to_acc
    3: required base.Amount amount
    4: required string description // нужно ли? Может вынести на уровень PostingBatch?
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
*/
struct PostingPlan {
    1: required PlanID id
    2: required list<PostingBatch> batch_list
}

/**
* Описывает единицу пополнения плана:
* id - id плана, к которому применяется данное изменение
* batch - набор проводок, который нужно добавить в план
*/
struct PostingPlanChange {
   1: required PlanID id
   2: required PostingBatch batch
}

union ClockState {
    // для новых операций
    1: VectorClockState vector
    // для старых операций, для обратной совместимости
    2: LatestClockState latest
}

struct VectorClockState {
    // позволяет хранить не только клок(оффсеты партиций), но также operation_id, сгенерированный сервисом,
    // для проверки статуса операции, а, возможно, и для более сложной логики
    1: required base.Opaque state
}

struct LatestClockState {
}

exception AccountNotFound {
    1: required AccountID account_id
}

exception PlanNotFound {
    1: required PlanID plan_id
}

/**
* Возникает в случае, если переданы некорректные параметры в одной или нескольких проводках
* Или проводки не совпадают с шифром
*/
exception InvalidPostingParams {
    1: required map<Posting, string> wrong_postings
}

exception NotReady {}

service Accounter {

    /**
    * Валидация касательно дублирования предыдущего холда и совпадения в нём проводок будет проведена, если
    * предыдущий холд уже был считан и есть в базе. Иначе этой валидации не будет, холд запишется, но не будет учтён.
    **/
    ClockState Hold(1: PostingPlanChange plan_change) throws (
        1: InvalidPostingParams e1,
        2: base.InvalidRequest e2
    )

    /**
    * После коммита происходит очистка данных в системе, последующие ретраи коммитов будут выдавать InvalidRequest
    **/
    ClockState CommitPlan(1: PostingPlan plan, 2: ClockState state) throws (
        1: InvalidPostingParams e1, // cipher is not matching, postings are different from hold
        2: base.InvalidRequest e2, // no hold found
        3: NotReady e3
    )

    ClockState RollbackPlan(1: PostingPlan plan, 2: ClockState state) throws (
        1: InvalidPostingParams e1, // cipher is not matching, postings are different from hold
        2: base.InvalidRequest e2, // no hold found
        3: NotReady e3
    )

    Balance GetBalanceByID(1: AccountID id, 2: ClockState state) throws (
        1: AccountNotFound e1,
        2: NotReady e2
    )

    /**
    * Создание аккаунтов проводится в Lazy режиме, так что state нужен для указания операции, после которой можно считать
    * аккаунт созданным.
    **/
    Account GetAccountByID(1: AccountID id, 2: ClockState state) throws (
        1: AccountNotFound e1,
        2: NotReady e2
    )
}

enum Operation {
    HOLD
    COMMIT
    ROLLBACK
}

struct MigrationPostingPlan {
    1: required PlanID plan_id
    2: required BatchID batch_id
    3: required AccountID account_from_id
    4: required AccountID account_to_id
    5: required base.Amount amount
    6: required base.CurrencySymbolicCode currency_symb_code
    7: required string description
    8: required base.Timestamp creation_time
    9: required Operation operation
}

service MigrationHelper {
    void migratePostingPlans(1: list<MigrationPostingPlan> postings)
    void migrateAccounts(1: list<Account> accountList)
}
