SET TERM ^ ;

CREATE OR ALTER procedure hp_pdn_get_from_equifax_bjson (
    bls_id d_id,
    rep_date d_date)
returns (
    creduid d_str_code,
    credcurrency d_str_code,
    creddate d_date,
    credenddate d_date,
    credenddatefact d_date,
    credupdate d_date,
    credsumdebt d_currency,
    credsumoverdue d_currency,
    creddayoverdue d_integer,
    credfullcost d_currency,
    credsum d_currency,
    credpartnertype d_str_10,
    credtype d_str_10,
    credcollateral d_integer,
    credcollateralfactenddate d_date,
    credguarantee d_integer,
    credguaranteefactenddate d_date,
    credcategory d_str_10,
    credconsumer d_smallint,
    credratio d_str_10,
    credpurpose d_str_10,
    credcollateralitemtype d_str_10,
    credactive_str d_str_255,
    signcreditcard d_bool,
    fullcurrentdebt d_currency,
    minsumpaycc d_currency,
    percentenddate d_date,
    credit_line_type d_str_10,
    cred_owner_type d_str_10,
    average_payment_date d_date,
    average_payment_sum d_currency,
    gracedate d_date,
    graceenddate d_date,
    dealsigncreditcard d_smallint,
    fullcost_sum d_currency,
    fullcost_date d_date,
    debtcurr_opsum d_currency,
    debtcurr_othersum d_currency,
    debtcurr_percentsum d_currency,
    debtoverdue_opsum d_currency,
    debtoverdue_percentsum d_currency,
    debtoverdue_othersum d_currency,
    debtoverdue_date d_date)
as
declare variable jso_full char(36) character set ascii;
declare variable json_full d_blob_text;
declare variable json_ok boolean;
declare variable loan_path d_str_long;
declare variable item_path d_str_long;
declare variable col_name d_str_long;
declare variable col_path d_str_long;
declare variable col_type d_str_code;
declare variable val_type d_str_code;
declare variable loan_count d_integer;
declare variable fact_rec_no d_integer;
declare variable i d_integer;
declare variable j d_integer;
declare variable cnt d_integer;
declare variable cnt2 d_integer;
declare variable credguaranteefactenddate_tmp d_date;
declare variable credcollateralfactenddate_tmp d_date;
declare variable credcollateraldate_tmp d_date;
declare variable credcollateraldate d_date;
declare variable credcollateralsum_tmp d_currency;
declare variable credcollateralsum d_currency;
declare variable first_sum d_currency;
declare variable credfullcostdate d_date;
declare variable credstartdebtdate d_date;

declare function js (
    handle char(36) character set ascii,
    path d_str_long,
    def d_str_8100 = null)
returns d_str_8100
as
begin
  if (handle is null) then
    return def;
  return BJSON.GET_S(handle, path, def);
end

declare function arr_len_at (
    handle char(36) character set ascii,
    path d_str_long)
returns d_integer
as
  declare variable t d_str_code;
begin
  if (handle is null) then
    return 0;
  if (coalesce(path, '') <> '' and BJSON.EXIST(handle, path) is false) then
    return 0;
  t = BJSON.GET_TYPE(handle, coalesce(path, ''));
  if (t = 'Array') then
    return coalesce(BJSON.LEN(handle, coalesce(path, '')), 0);
  else if (t = 'Object') then
    return 1;
  else if (t is null) then
    return 0;
  else
    exception e_default coalesce(path, '') || ' is not Array/Object';
end

declare function item_path_at (
    handle char(36) character set ascii,
    path d_str_long,
    idx d_integer)
returns d_str_long
as
  declare variable t d_str_code;
begin
  t = BJSON.GET_TYPE(handle, coalesce(path, ''));
  if (t = 'Object') then
    return path;
  if (coalesce(path, '') = '') then
    return '[' || idx || ']';
  return path || '[' || idx || ']';
end

declare procedure get_debt_from_json (
    handle char(36) character set ascii,
    path d_str_long)
returns (
    pos d_integer,
    debt_sign d_bool,
    calc_date d_date,
    debt_date d_date,
    first_sum d_currency,
    debt_op_sum d_currency,
    debt_sum d_currency)
as
  declare variable cnt d_integer;
  declare variable calc_date_str d_str_255;
  declare variable debt_date_str d_str_255;
  declare variable p d_str_long;
  declare variable t d_str_code;
begin
  if (handle is null) then
    exit;
  if (coalesce(path, '') <> '' and BJSON.EXIST(handle, path) is false) then
    exit;

  t = BJSON.GET_TYPE(handle, coalesce(path, ''));
  if (t = 'Array') then
    cnt = coalesce(BJSON.LEN(handle, coalesce(path, '')), 0);
  else if (t = 'Object') then
    cnt = 1;
  else if (t is null) then
    exit;
  else
    exception e_default coalesce(path, '') || ' is not Array/Object';

  pos = 0;
  if (cnt > 1) then
    exception e_default BJSON.ToJSON(BJSON.GET(handle, path));
  while (pos < cnt) do
  begin
    if (t = 'Object') then
      p = path;
    else if (coalesce(path, '') = '') then
      p = '[' || pos || ']';
    else
      p = path || '[' || pos || ']';
    debt_sign = BJSON.GET_S(handle, p || '.sign', 1);
    debt_op_sum = replace(replace(BJSON.GET_S(handle, p || '.opSum', 0), ',', '.'), '-', 0);
    debt_sum = replace(replace(BJSON.GET_S(handle, p || '.sum', 0), ',', '.'), '-', 0);
    first_sum = replace(replace(BJSON.GET_S(handle, p || '.firstSum', 0), ',', '.'), '-', 0);
    calc_date_str = BJSON.GET_S(handle, p || '.calcDate');
    debt_date_str = BJSON.GET_S(handle, p || '.date');
    calc_date = iif(calc_date_str = '-', null, calc_date_str);
    debt_date = iif(debt_date_str = '-', null, debt_date_str);

    if (debt_sum = 0) then
      debt_date = null;

    suspend;
    pos = pos + 1;
  end
end

declare procedure get_payment_from_json (
    handle char(36) character set ascii,
    path d_str_long)
returns (
    lastpayoutdate d_date)
as
  declare variable cnt d_integer;
  declare variable lastpayoutdate_str d_str_255;
  declare variable lastpayoutdate_tmp d_date;
  declare variable pos d_integer;
  declare variable p d_str_long;
  declare variable t d_str_code;
begin
  if (handle is null) then
    exit;
  if (coalesce(path, '') <> '' and BJSON.EXIST(handle, path) is false) then
    exit;

  t = BJSON.GET_TYPE(handle, coalesce(path, ''));
  if (t = 'Array') then
    cnt = coalesce(BJSON.LEN(handle, coalesce(path, '')), 0);
  else if (t = 'Object') then
    cnt = 1;
  else if (t is null) then
    exit;
  else
    exception e_default coalesce(path, '') || ' is not Array/Object';

  pos = 0;
  while (pos < cnt) do
  begin
    if (t = 'Object') then
      p = path;
    else if (coalesce(path, '') = '') then
      p = '[' || pos || ']';
    else
      p = path || '[' || pos || ']';
    lastpayoutdate_str = BJSON.GET_S(handle, p || '.lastpayoutdate');
    lastpayoutdate_tmp = iif(lastpayoutdate_str = '-', null, lastpayoutdate_str);

    if (coalesce(lastpayoutdate_tmp, '01.01.1900') > coalesce(lastpayoutdate, '01.01.1900')) then
      lastpayoutdate = lastpayoutdate_tmp;
    pos = pos + 1;
  end
  suspend;
end

declare procedure get_contract_amount (
    handle char(36) character set ascii,
    path d_str_long)
returns (
    summ d_currency,
    currency d_str_code)
as
  declare variable cnt d_integer;
  declare variable pos d_integer;
  declare variable p d_str_long;
  declare variable t d_str_code;
begin
  if (handle is null) then
    exit;
  if (coalesce(path, '') <> '' and BJSON.EXIST(handle, path) is false) then
    exit;

  t = BJSON.GET_TYPE(handle, coalesce(path, ''));
  if (t = 'Array') then
    cnt = coalesce(BJSON.LEN(handle, coalesce(path, '')), 0);
  else if (t = 'Object') then
    cnt = 1;
  else if (t is null) then
    exit;
  else
    exception e_default coalesce(path, '') || ' is not Array/Object';

  pos = 0;
  summ = 0;
  while (pos < cnt) do
  begin
    if (t = 'Object') then
      p = path;
    else if (coalesce(path, '') = '') then
      p = '[' || pos || ']';
    else
      p = path || '[' || pos || ']';
    pos = pos + 1;
    summ = summ + cast(replace(replace(BJSON.GET_S(handle, p || '.sum', 0), ',', '.'), '-', 0) as d_currency);
    currency = BJSON.GET_S(handle, p || '.currency');
  end

  suspend;
end

declare function str2date (date_str d_str_20)
returns d_date
as
begin
  return iif(date_str = '-', null, date_str);
end

declare function my_strtonum (
    num_str d_str_code)
returns d_double
as
begin
  return replace(num_str, ',', '.');
  when any do
    return 0;
end

declare function str2curr(str d_str_255)
returns d_currency
as
begin
  return replace(str, ',', '.');
  when any do
    return null;
end

begin
---------------Начало----------------------
  json_full = '';
  jso_full = null;

  if (bls_id is not null) then
  begin
    select cast(blx_blob as d_blob_text)
    from hp_get_blobex_blob(:bls_id)
    into :json_full;
  end

  if (coalesce(json_full, '') not starting with '{') then
    exception e_default 'wrong json in bls_id: ' || bls_id;

  jso_full = BJSON.PARSE(json_full);

  begin
    loan_count = 0;
    fact_rec_no = 0;

    begin
      loan_count = arr_len_at(jso_full, 'response.basePart.contract');
      when any do loan_count = 0;
    end

    while (fact_rec_no < loan_count) do
    begin
      fact_rec_no = fact_rec_no + 1;
      loan_path = item_path_at(jso_full, 'response.basePart.contract', fact_rec_no - 1);

      credGuarantee = 0;
      credCollateral = 0;

      credUid = js(jso_full, loan_path || '.uid.id', null);                                                                -- uid

      if (BJSON.EXIST(jso_full, loan_path || '.deal') is false
          or BJSON.GET_TYPE(jso_full, loan_path || '.deal') is distinct from 'Object') then -- RFCRU-2502
        continue;

      if (credUid is null) then
        credUid = js(jso_full, loan_path || '.extraData.2', null);

      credPartnerType = js(jso_full, loan_path || '.extraData.5', null);                                                    -- Тип партнера
      credEnddatefact = replace(js(jso_full, loan_path || '.contractEnd.date', '01.01.1900'), '-', '01.01.1900');            -- Дата фактического прекращения обязательства
      credFullCost = my_strtonum(js(jso_full, loan_path || '.fullCost.percent', 0));                                         -- ПСК %%
      credFullCostDate = str2date(js(jso_full, loan_path || '.fullCost.date', null));
      average_payment_date = str2date(js(jso_full, loan_path || '.averagePayment.date', null));
      average_payment_sum = my_strtonum(js(jso_full, loan_path || '.averagePayment.sum', null));
      credStartDebtDate = str2date(js(jso_full, loan_path || '.credStartDebt.date', null));

      if (credenddatefact = '01.01.1900') then credenddatefact = null;

      credDate = replace(js(jso_full, loan_path || '.deal.date', '01.01.1900'), '-', '01.01.1900');

      select summ, currency
      from get_contract_amount(:jso_full, :loan_path || '.contractAmount')
      into credSum, credCurrency;           -- Сумма обязательства, Валюта обязательства

      credEnddate = replace(js(jso_full, loan_path || '.deal.endDate', '31.12.2999'), '-', '31.12.2999'); -- Дата прекращения обязательства субъекта по условиям сделки
      credRatio = js(jso_full, loan_path || '.deal.ratio', null);                -- Код вида участия в сделке
      credCategory = js(jso_full, loan_path || '.deal.category', null);          -- Код типа сделки
      credType = js(jso_full, loan_path || '.deal.typeValue', js(jso_full, loan_path || '.deal.type', null));  -- Код вида займа (кредита)   --- У Антона в сервисе бывает меняется без его ведома(!!!!) type на typeValue. Задолбал. Ставим такой костыль.
      credConsumer = js(jso_full, loan_path || '.deal.signCredit', null);        -- Признак потребительского кредита (займа)
      signCreditCard = js(jso_full, loan_path || '.deal.signCreditCard', 0);     -- Признак использования платежной карты
      credGuarantee = js(jso_full, loan_path || '.guarantees.sign', 0);          -- Признак наличия поручительства
      cred_owner_type = js(jso_full, loan_path || '.deal.credOwnerType', null);  -- Код вида кредитора – заимодавца
      credit_line_type = js(jso_full, loan_path || '.deal.signCreditLine', null);-- Признак кредитной линии
      if (credit_line_type = 1) then
        credit_line_type = js(jso_full, loan_path || '.deal.creditLineType', null);-- Код типа кредитной линии

      credPurpose = null;

      if (BJSON.EXIST(jso_full, loan_path || '.deal.purpose')) then
      begin
        val_type = BJSON.GET_TYPE(jso_full, loan_path || '.deal.purpose');
        if (val_type = 'Array') then
          credPurpose = iif(arr_len_at(jso_full, loan_path || '.deal.purpose') = 0, null,
                            js(jso_full, item_path_at(jso_full, loan_path || '.deal.purpose', 0), null));            -- Код цели займа (кредита)
        else if (val_type = 'Object') then
          credPurpose = null;
        else
          credPurpose = js(jso_full, loan_path || '.deal.purpose', null);            -- Код цели займа (кредита)
      end
      credCollateral = js(jso_full, loan_path || '.collaterals.sign', 0);        -- Признак наличия залога

      credGuaranteeFactEndDate = null;
      credGuaranteeFactEndDate_tmp = null;
      if (credGuarantee = 1) then
      begin
        i = 0;
        cnt = arr_len_at(jso_full, loan_path || '.guarantees.guarantee');
        while (i < cnt) do
        begin
          item_path = item_path_at(jso_full, loan_path || '.guarantees.guarantee', i);
          credGuaranteeFactEndDate_tmp = replace(js(jso_full, item_path || '.factEndDate', '01.01.1900'), '-', '01.01.1900');      --- Дата фактического прекращения поручительства
          if (credGuaranteeFactEndDate_tmp is not null and coalesce(credGuaranteeFactEndDate, '01.01.1900') < credGuaranteeFactEndDate_tmp) then
            credGuaranteeFactEndDate = credGuaranteeFactEndDate_tmp;
          i = i + 1;
        end
      end

      if (credguaranteefactenddate = '01.01.1900') then credguaranteefactenddate = null;

      credSumDebt = 0;         -- Сумма общей задолженности
      credUpdate = null;       -- Дата расчета
      credSumOverdue = 0;      -- Сумма просроченной задолженности
      credDayOverdue = 0;      -- Дней просрочки
      first_sum = 0;
      fullCurrentDebt = 0;

      select calc_date, debt_op_sum, debt_sum
      from get_debt_from_json(:jso_full, :loan_path || '.debtCurrent')
      where debt_sign = 1
      order by calc_date desc, debt_sum desc
      rows 1
      into credUpdate, credSumDebt, fullCurrentDebt;

      if (credUpdate is null) then
        credUpdate = maxvalue(coalesce(average_payment_date, '01.01.1900'),
                              coalesce(credenddatefact, '01.01.1900'),
                              coalesce(credFullCostDate, '01.01.1900'),
                              coalesce(credStartDebtDate, '01.01.1900'),
                              coalesce(credDate, '01.01.1900'),
                              coalesce((select lastpayoutdate from get_payment_from_json(:jso_full, :loan_path || '.payments')), '01.01.1900'));

      select first_sum
      from get_debt_from_json(:jso_full, :loan_path || '.debt')
      order by calc_date desc, first_sum desc
      rows 1
      into first_sum;

      if (credSum = 0) then
        credSum = maxvalue(credSumDebt, first_sum);

      select debt_date, debt_sum
      from get_debt_from_json(:jso_full, :loan_path || '.debtOverdue')
      order by calc_date desc, debt_sum desc
      rows 1
      into debtoverdue_date, credSumOverdue;

      if (debtoverdue_date > rep_date or credSumOverdue = 0) then
        debtoverdue_date = null;

      credDayOverdue = rep_date - coalesce(debtoverdue_date, rep_date);

      credActive_str = case
        when fullCurrentDebt + credSumOverdue = 0 and coalesce(credEndDateFact, '01.01.1900') <> '01.01.1900' then 'договор закрыт'
        when credDayOverdue > 364 then 'договор активен, просрочка 365+ дней'
        when credDayOverdue > 90 then 'договор активен, просрочка до 90-365 дней'
        when credDayOverdue > 30 then 'договор активен, просрочка до 30-90 дней'
        when credDayOverdue > 0 then 'договор активен, просрочка до 30 дней'
        else 'договор активен'
      end;

      -- залогов может быть несколько. показываем залог только по активным займам + показываем только действующий залог
      -- + если несколько действующих, показываем с большей суммой, далее с более поздней датой начала
      credCollateralItemType = null;
      credCollateralFactEndDate = null;
      credCollateralFactEndDate_tmp = null;
      credCollateralDate_tmp = null;
      credCollateralDate = null;
      credCollateralSum_tmp = 0;
      credCollateralSum = 0;

      if (credCollateral = 1) then
      begin
        i = 0;
        cnt = coalesce(BJSON.LEN(jso_full, loan_path || '.collaterals'), 0);

        while (i < cnt) do
        begin
          col_name = BJSON.NAMEOF(jso_full, loan_path || '.collaterals', i);
          col_path = loan_path || '.collaterals.' || col_name;
          col_type = BJSON.GET_TYPE(jso_full, col_path);

          if (col_type = 'Array') then
          begin
            j = 0;
            cnt2 = coalesce(BJSON.LEN(jso_full, col_path), 0);
            while (j < cnt2) do
            begin
              item_path = col_path || '[' || j || ']';
              credCollateralSum_tmp = my_strtonum(js(jso_full, item_path || '.sum', 0));
              credCollateralDate_tmp = replace(js(jso_full, item_path || '.date', '01.01.1900'), '-', '01.01.1900');
              credCollateralFactEndDate_tmp = replace(js(jso_full, item_path || '.factEndDate', '01.01.1900'), '-', '01.01.1900');
              if (rep_date between credCollateralDate_tmp and credCollateralFactEndDate_tmp
                and (credCollateralDate is null
                    or credCollateralSum_tmp > credCollateralSum
                    or (credCollateralSum_tmp = credCollateralSum and credCollateralDate_tmp > credCollateralDate)
                    )
                  )
              then
              begin
                credCollateralDate = credCollateralDate_tmp;
                credCollateralFactEndDate = credCollateralFactEndDate_tmp;
                credCollateralSum = credCollateralSum_tmp;
                credCollateralItemType = js(jso_full, item_path || '.itemType', null);      --- Код предмета залога
              end
              j = j + 1;
            end
          end
          else if (col_type = 'Object') then
          begin
            item_path = col_path;
            credCollateralSum_tmp = my_strtonum(js(jso_full, item_path || '.sum', 0));
            credCollateralDate_tmp = replace(js(jso_full, item_path || '.date', '01.01.1900'), '-', '01.01.1900');
            credCollateralFactEndDate_tmp = replace(js(jso_full, item_path || '.factEndDate', '01.01.1900'), '-', '01.01.1900');
            if (rep_date between credCollateralDate_tmp and credCollateralFactEndDate_tmp
              and (credCollateralDate is null
                  or credCollateralSum_tmp > credCollateralSum
                  or (credCollateralSum_tmp = credCollateralSum and credCollateralDate_tmp > credCollateralDate)
                  )
                )
            then
            begin
              credCollateralDate = credCollateralDate_tmp;
              credCollateralFactEndDate = credCollateralFactEndDate_tmp;
              credCollateralSum = credCollateralSum_tmp;
              credCollateralItemType = js(jso_full, item_path || '.itemType', null);      --- Код предмета залога
            end
          end

          i = i + 1;
        end
      end
-- paymentTerms, deal, fullCost и др.

      begin
          gracedate = str2date(js(jso_full, loan_path || '.paymentTerms.graceDate'));
          graceenddate = str2date(js(jso_full, loan_path || '.paymentTerms.graceEndDate'));
--          minsumpaycc = str2curr(js(jso_full, loan_path || '.paymentTerms.minSumPayCc'));
          signcreditcard = js(jso_full, loan_path || '.deal.signCreditCard');
          fullcost_sum  = str2curr(js(jso_full, loan_path || '.fullCost.sum'));
          fullcost_date = str2date(js(jso_full, loan_path || '.fullCost.date'));

          if (arr_len_at(jso_full, loan_path || '.debtCurrent') > 0) then
          begin
            item_path = item_path_at(jso_full, loan_path || '.debtCurrent', 0);
            debtcurr_opsum       = str2curr(js(jso_full, item_path || '.opSum'));
            debtcurr_percentsum  = str2curr(js(jso_full, item_path || '.percentSum'));
            debtcurr_othersum    = str2curr(js(jso_full, item_path || '.otherSum'));
          end

          if (arr_len_at(jso_full, loan_path || '.debtOverdue') > 0) then
          begin
            item_path = item_path_at(jso_full, loan_path || '.debtOverdue', 0);
            debtoverdue_opsum       = str2curr(js(jso_full, item_path || '.opSum'));
            debtoverdue_percentsum  = str2curr(js(jso_full, item_path || '.percentSum'));
            debtoverdue_othersum    = str2curr(js(jso_full, item_path || '.otherSum'));
          end
       end
      minSumPayCc = my_strtonum(js(jso_full, loan_path || '.paymentTerms.minSumPayCc', null));   -- Сумма минимального платежа по кредитной карте
      percentEndDate = replace(js(jso_full, loan_path || '.paymentTerms.percentEndDate', '01.01.1900'), '-', '01.01.1900'); -- Дата окончания срока уплаты процентов

      if (credCollateralFactEndDate = '01.01.1900') then credCollateralFactEndDate = null;
      if (percentEndDate = '01.01.1900') then percentEndDate = null;

      suspend;
    end

    json_ok = BJSON.FREE(jso_full);
    jso_full = null;
    when any do
    begin
      if (jso_full is not null) then
        json_ok = BJSON.FREE(jso_full);
      exception;
    end
  end
end
^

SET TERM ; ^
