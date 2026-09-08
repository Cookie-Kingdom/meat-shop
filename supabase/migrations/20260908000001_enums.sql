-- Enums. Source: API_DATA_MODEL.md "Enums" (v0.2, 8 Sep 2026).

create type user_role         as enum ('L1_OWNER', 'L2_BRANCH_ADMIN', 'L3_CM_OPERATOR');
create type location_kind     as enum ('CENTRAL', 'CHEF_HOUSE', 'BRANCH');
create type rice_model        as enum ('EXTERNAL_COOKED', 'SELF_COOK');
create type lot_state         as enum ('PO_CREATED','IN_TRANSIT','CM_RECEIVED','SMOKING',
                                       'LOT_CLOSED','RETURN_SCHEDULED','CENTRAL_STOCK',
                                       'ALLOCATED','AT_BRANCH','CONSUMED');
create type item_type         as enum ('SMOKED_MEAT','CHILLI_PASTE','COOKED_RICE',
                                       'RAW_RICE','PACKAGING');
create type stock_state       as enum ('IN_TRANSIT','FROZEN','READY');
create type movement_type     as enum ('INTAKE','TRANSFER_OUT','TRANSFER_IN','THAW_OUT',
                                       'THAW_IN','SALE','WASTE','GIVEAWAY','ADJUSTMENT',
                                       'REVERSAL');
create type transport_route   as enum ('FOODIVA_TO_CM','CM_TO_FOODIVA','CENTRAL_TO_BRANCH');
create type freight_alloc     as enum ('BY_LOT_WEIGHT','EQUAL_SPLIT','MANUAL');
create type report_status     as enum ('OPEN','CLOSED','UNLOCKED');
create type unlock_target     as enum ('DAILY_REPORT','LOT');
create type unlock_status     as enum ('PENDING','APPROVED','REJECTED','EXPIRED');
create type expense_kind      as enum ('INVESTMENT','MONTHLY_FIXED','OTHER');
create type notification_kind as enum ('YIELD_ALERT','FIFO_OVERRIDE','MATERIAL_LOW',
                                       'RECEIPT_VARIANCE','LOT_CLOSED','UNLOCK_REQUEST',
                                       'RETURN_PICKUP_DUE','DIFF_OVER_THRESHOLD');
