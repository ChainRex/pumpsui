module pumpsui::pumpsui_core {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::math;
    use testsui::testsui::{ TESTSUI };
    use pumpsui::bonding_curve;

    const DECIMALS: u64 = 1_000_000_000;
    const MAX_SUPPLY: u64 = 1_000_000_000 * DECIMALS;
    const FUNDING_SUI: u64 = 20000 * DECIMALS;
    const FUNDING_TOKEN: u64 = (MAX_SUPPLY * 4) / 5;

    const EInsufficientSUI: u64 = 1001;
    const EInsufficientTokenSupply: u64 = 1002;
    const EInsufficientToken: u64 = 1003;
    const EInsufficientPoolBalance: u64 = 1004;

    public struct Pool<phantom T> has key {
        id: UID,
        coin_balance: Balance<T>,
        sui_balance: Balance<TESTSUI>,
    }

    public struct TreasuryCapHolder<phantom T> has key {
        id: UID,
        treasury_cap: TreasuryCap<T>
    }

    /// 通过将treasury_cap包装，用户就只能在本合约的限制下铸造或销毁代币
    public entry fun create_pool<T>(
        treasury_cap: TreasuryCap<T>,
        ctx: &mut TxContext
    ) {

        let pool = Pool<T> {
            id: object::new(ctx),
            coin_balance: balance::zero(),
            sui_balance: balance::zero()
        };

        let treasury_cap_holder = TreasuryCapHolder<T> {
            id: object::new(ctx),
            treasury_cap,
        };

        transfer::share_object(pool);
        transfer::share_object(treasury_cap_holder)
    }

    public entry fun buy<T>(
        pool: &mut Pool<T>,
        treasury_cap_holder: &mut TreasuryCapHolder<T>,
        payment: Coin<TESTSUI>,
        ctx: &mut TxContext
    ) {
        let payment_value = coin::value(&payment);
        assert!(payment_value > 0, EInsufficientSUI);

        let mut payment_balance = coin::into_balance(payment);
        
        let current_pool_balance = balance::value(&pool.sui_balance);
        let actual_payment_value = if (current_pool_balance + payment_value > FUNDING_SUI) {
            // 如果超过募资目标，计算实际需要的金额
            let refund_amount = (current_pool_balance + payment_value) - FUNDING_SUI;
            // 从支付金额中分离出需要退还的部分
            let refund_balance = balance::split(&mut payment_balance, refund_amount);
            // 创建退款代币并转账给用户
            let refund_coin = coin::from_balance(refund_balance, ctx);
            transfer::public_transfer(
                refund_coin,
                tx_context::sender(ctx)
            );
            payment_value - refund_amount
        } else {
            payment_value
        };

        // 使用实际支付金额计算可获得的代币数量
        let current_supply = coin::total_supply(&treasury_cap_holder.treasury_cap);
        let token_amount = bonding_curve::calculate_buy_amount(actual_payment_value, current_supply);
        
        assert!(
            current_supply + token_amount <= MAX_SUPPLY,
            EInsufficientTokenSupply
        );

        // 将实际支付金额加入池中
        balance::join(
            &mut pool.sui_balance,
            payment_balance
        );

        coin::mint_and_transfer(
            &mut treasury_cap_holder.treasury_cap,
            token_amount,
            tx_context::sender(ctx),
            ctx
        );

        if (balance::value(&pool.sui_balance) >= FUNDING_SUI) {
            // TODO: 检查是否达到 FUNDING_SUI 阈值，如果达到则创建流动性池
        };
    }

    public entry fun sell<T>(
        pool: &mut Pool<T>,
        treasury_cap_holder: &mut TreasuryCapHolder<T>,
        token_coin: Coin<T>,
        ctx: &mut TxContext
    ) {
        let token_amount = coin::value(&token_coin);
        assert!(token_amount > 0, EInsufficientToken);

        let current_supply = coin::total_supply(&treasury_cap_holder.treasury_cap);
        let sui_return = bonding_curve::calculate_sell_return(token_amount, current_supply);

        let pool_balance = balance::value(&pool.sui_balance);
        assert!(
            pool_balance >= sui_return,
            EInsufficientPoolBalance
        );

        coin::burn(
            &mut treasury_cap_holder.treasury_cap,
            token_coin
        );

        let sui_coin = coin::from_balance(
            balance::split(&mut pool.sui_balance, sui_return),
            ctx
        );
        transfer::public_transfer(sui_coin, tx_context::sender(ctx));
    }

}
