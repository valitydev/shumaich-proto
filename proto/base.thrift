namespace java dev.vality.damsel.shumaich.base
namespace erlang base

/** Символьный код, уникально идентифицирующий валюту. */
typedef string CurrencySymbolicCode

/**
 * Отметка во времени согласно RFC 3339.
 *
 * Строка должна содержать дату и время в UTC в следующем формате:
 * `2016-03-22T06:12:27Z`.
 */
typedef string Timestamp

/** Сумма в минимальных денежных единицах. */
typedef i64 Amount

/** Непрозрачный для участника общения набор данных */
typedef binary Opaque

/**
 * Исключение, сигнализирующее о непригодных с точки зрения бизнес-логики входных данных
 */
exception InvalidRequest {
    /** Список пригодных для восприятия человеком ошибок во входных данных */
    1: required list<string> errors
}