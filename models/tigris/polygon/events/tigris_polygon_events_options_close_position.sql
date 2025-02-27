{{ config(
    
    schema = 'tigris_polygon',
    alias = 'options_close_position',
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['evt_block_time', 'evt_tx_hash', 'position_id', 'positions_contract']
    )
}}

WITH 

{% set close_position_tables = [
    'options_evt_TradeClosed',
    'Options_V2_evt_TradeClosed'
] %}

close_position_v2 AS (
    {% for close_position in close_position_tables %}
        SELECT
            '{{ 'v2.' + loop.index | string }}' as version,
            '2' as protocol_version,
            CAST(date_trunc('DAY', t.evt_block_time) AS date) as day, 
            CAST(date_trunc('MONTH', t.evt_block_time) AS date) as block_month, 
            t.evt_block_time, 
            t.evt_tx_hash,
            t.evt_index,
            t.id, 
            closePrice,
            payout,
            contract_address as project_contract_address
        FROM {{ source('tigristrade_v2_polygon', close_position) }} t
        {% if is_incremental() %}
        WHERE t.evt_block_time >= date_trunc('day', now() - interval '7' day)
        {% endif %}
        {% if not loop.last %}
        UNION ALL
        {% endif %}
    {% endfor %}
),

get_positions_contract as (
    SELECT 
        a.*,
        c.positions_contract 
    FROM 
    close_position_v2 a 
    INNER JOIN 
    {{ ref('tigris_polygon_events_contracts_positions') }} c 
        ON a.project_contract_address = c.trading_contract
        AND a.version = c.trading_contract_version
)

    SELECT 
        t.version,
        t.protocol_version,
        t.day, 
        t.block_month,
        t.evt_block_time, 
        t.evt_tx_hash,
        t.evt_index,
        t.id as position_id,
        COALESCE(o.open_price, l.open_price) as open_price,
        t.closePrice/1e18 as close_price,
        t.payout/1e18 - COALESCE(o.collateral, l.collateral) as profitnLoss, 
        COALESCE(o.collateral, l.collateral) as collateral,
        COALESCE(o.collateral_asset, l.collateral_asset) as collateral_asset,
        COALESCE(o.direction, l.direction) as direction, 
        COALESCE(o.pair, l.pair) as pair, 
        COALESCE(o.options_period, l.options_period) as options_period,
        COALESCE(o.referral, l.referral) as referral,
        COALESCE(o.trader, l.trader) as trader, 
        COALESCE(o.order_type, l.order_type) as order_type,
        t.project_contract_address,
        t.positions_contract
    FROM 
    get_positions_contract t 
    LEFT JOIN 
     {{ ref('tigris_polygon_events_options_open_position') }} o 
        ON t.id = o.position_id
        AND t.positions_contract = o.positions_contract
    LEFT JOIN 
     {{ ref('tigris_polygon_events_options_limit_order') }} l 
        ON t.id = l.position_id
        AND t.positions_contract = l.positions_contract
