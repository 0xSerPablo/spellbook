{{ config(
    schema = 'tokenlon_v5_ethereum',
    alias = 'rfq_v1_trades',
    
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index', 'trace_address'],
    post_hook = '{{ expose_spells(\'["ethereum"]\',
                                    "project",
                                    "tokenlon",
                                    \'["izayl"]\') }}'
    )
}} 
{% set blockchain = 'ethereum' %}
{% set project = 'tokenlon' %}
{% set project_version = '5' %}
-- block 12792553
{% set project_start_date = "timestamp '2021-07-09'" %}

WITH dexs AS (
    SELECT 
        evt_block_time        AS block_time,
        "userAddr"            AS taker,
        "makerAddr"           AS maker,
        "takerAssetAmount"    AS token_sold_amount_raw,
        "makerAssetAmount"    AS token_bought_amount_raw,
        cast(NULL as double)  AS amount_usd,
        "takerAssetAddr"      AS token_sold_address,
        "makerAssetAddr"      AS token_bought_address,
        contract_address      AS project_contract_address,
        evt_tx_hash           AS tx_hash,
        CAST(ARRAY[] as array<bigint>) AS trace_address,
        evt_index
    FROM
        {{ source('tokenlon_v5_ethereum', 'RFQv1_evt_FillOrder') }} 
    {% if is_incremental() %}
    WHERE evt_block_time >= date_trunc('day', now() - interval '7' day) 
    {% endif %}
)

SELECT
    '{{blockchain}}'                                            AS blockchain,
    '{{project}}'                                               AS project,
    '{{project_version}}'                                       AS version,
    TRY_CAST(date_trunc('DAY', dexs.block_time) AS date)        AS block_date,
    CAST(date_trunc('month', dexs.block_time) AS date)          AS block_month,
    dexs.block_time,
    erc20a.symbol                                               AS token_bought_symbol,
    erc20b.symbol                                               AS token_sold_symbol,
    CASE
        WHEN lower(erc20a.symbol) > lower(erc20b.symbol) THEN concat(erc20b.symbol, '-', erc20a.symbol)
        ELSE concat(erc20a.symbol, '-', erc20b.symbol)
    END                                                         AS token_pair,
    dexs.token_bought_amount_raw / power(10, erc20a.decimals)   AS token_bought_amount,
    dexs.token_sold_amount_raw / power(10, erc20b.decimals)     AS token_sold_amount,
    CAST(dexs.token_bought_amount_raw AS DECIMAL(38, 0))        AS token_bought_amount_raw,
    CAST(dexs.token_sold_amount_raw AS DECIMAL(38, 0))          AS token_sold_amount_raw,
    coalesce(dexs.
        amount_usd, 
        (dexs.token_bought_amount_raw / power(10, p_bought.decimals)) * p_bought.price, 
        (dexs.token_sold_amount_raw / power(10, p_sold.decimals)) * p_sold.price
    )                                                           AS amount_usd,
    dexs.token_bought_address,
    dexs.token_sold_address,
    coalesce(dexs.taker, tx."from")                               AS taker,
    dexs.maker,
    dexs.project_contract_address,
    dexs.tx_hash,
    tx."from" AS tx_from,
    tx.to AS tx_to,
    dexs.trace_address,
    dexs.evt_index
FROM dexs
INNER JOIN {{ source('ethereum', 'transactions') }} tx 
    ON tx.hash = dexs.tx_hash
    {% if not is_incremental() %}
    AND tx.block_time >= {{project_start_date}}
    {% endif %} 
    {% if is_incremental() %}
    AND tx.block_time >= date_trunc('day', now() - interval '7' day) 
    {% endif %}
LEFT JOIN {{ ref('tokens_erc20') }} erc20a 
    ON erc20a.contract_address = dexs.token_bought_address
    AND erc20a.blockchain = 'ethereum'
LEFT JOIN {{ ref('tokens_erc20') }} erc20b 
    ON erc20b.contract_address = dexs.token_sold_address
    AND erc20b.blockchain = 'ethereum'
LEFT JOIN {{ source('prices', 'usd') }} p_bought 
    ON p_bought.minute = date_trunc('minute', dexs.block_time)
    AND p_bought.contract_address = dexs.token_bought_address
    AND p_bought.blockchain = 'ethereum' 
    {% if not is_incremental() %}
    AND p_bought.minute >= {{project_start_date}}
    {% endif %} 
    {% if is_incremental() %}
    AND p_bought.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', dexs.block_time)
    AND p_sold.contract_address = dexs.token_sold_address
    AND p_sold.blockchain = 'ethereum' 
    {% if not is_incremental() %}
    AND p_sold.minute >= {{project_start_date}}
    {% endif %}
    {% if is_incremental() %}
    AND p_sold.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}