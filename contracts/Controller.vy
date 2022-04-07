# @version 0.3.1

interface AMM:
    def A() -> uint256: view
    def base_price() -> uint256: view
    def active_band() -> int256: view
    def p_current_up(n: int256) -> uint256: view
    def p_current_down(n: int256) -> uint256: view
    def deposit_range(user: address, amount: uint256, n1: int256, n2: int256, move_coins: bool): nonpayable
    def read_user_tick_numbers(_for: address) -> int256[2]: view
    def get_sum_y(user: address) -> uint256: view
    def withdraw(user: address, move_to: address) -> uint256[2]: view
    def get_x_down(user: address) -> uint256: view
    def get_rate_mul() -> uint256: view

interface ERC20:
    def totalSupply() -> uint256: view
    def mint(_to: address, _value: uint256) -> bool: nonpayable
    def burnFrom(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable


event Borrow:  # It's in reality loan status
    user: indexed(address)
    collateral_amount: uint256
    loan_amount: uint256
    n1: int256
    n2: int256


struct Loan:
    initial_debt: uint256
    rate_mul: uint256


COLLATERAL_TOKEN: immutable(address)
BORROWED_TOKEN: immutable(address)
STABLECOIN: immutable(address)
MIN_LIQUIDATION_DISCOUNT: constant(uint256) = 10**16 # Start liquidating when threshold reached
MAX_TICKS: constant(int256) = 50
MIN_TICKS: constant(int256) = 5

loans: HashMap[address, Loan]
total_debt: Loan

amm: public(address)
admin: public(address)
ltv: public(uint256)  # Loan to value at 1e18 base
liquidation_discount: public(uint256)
loan_discount: public(uint256)

logAratio: public(uint256)  # log(A / (A - 1))


@external
def __init__(admin: address, collateral_token: address, borrowed_token: address,
             stablecoin: address,
             loan_discount: uint256, liquidation_discount: uint256):
    self.admin = admin
    COLLATERAL_TOKEN = collateral_token
    BORROWED_TOKEN = borrowed_token
    STABLECOIN = stablecoin

    assert loan_discount > liquidation_discount
    assert liquidation_discount >= MIN_LIQUIDATION_DISCOUNT
    self.liquidation_discount = liquidation_discount
    self.loan_discount = loan_discount


@internal
@pure
def log2(_x: uint256) -> uint256:
    # adapted from: https://medium.com/coinmonks/9aef8515136e
    # and vyper log implementation
    res: uint256 = 0
    x: uint256 = _x
    for i in range(8):
        t: uint256 = 2**(7 - i)
        p: uint256 = 2**t
        if x >= p * 10**18:
            x /= p
            res += t * 10**18
    d: uint256 = 10**18
    for i in range(34):  # 10 decimals: math.log(10**10, 2) == 33.2. Need more?
        if (x >= 2 * 10**18):
            res += d
            x /= 2
        x = x * x / 10**18
        d /= 2
    return res


@external
def set_amm(amm: address):
    assert msg.sender == self.admin
    assert self.amm == ZERO_ADDRESS
    self.amm = amm
    A: uint256 = AMM(amm).A()
    self.logAratio = self.log2(A * 10**18 / (A - 1))


@external
def set_admin(admin: address):
    assert msg.sender == self.admin
    self.admin = admin


@internal
@view
def _debt(user: address) -> (uint256, uint256):
    rate_mul: uint256 = AMM(self.amm).get_rate_mul()
    loan: Loan = self.loans[user]
    return (loan.initial_debt * rate_mul / loan.rate_mul, rate_mul)


@external
@view
def debt(user: address) -> uint256:
    return self._debt(user)[0]


# n1 = log((collateral * p_base * (1 - discount)) / debt) / log(A / (A - 1)) - N / 2
# round that down
# n2 = n1 + N
@internal
@view
def _calculate_debt_n1(collateral: uint256, debt: uint256, N: uint256) -> int256:
    amm: address = self.amm
    n0: int256 = AMM(amm).active_band()
    p0: uint256 = AMM(amm).p_current_down(n0)
    # TODO If someone pumped the AMM and deposited
    # - it will be sold if the price goes back down
    # But this needs to be tested?

    collateral_val: uint256 = (collateral * p0 / 10**18 * (10**18 - self.loan_discount))
    assert collateral_val >= debt, "Debt is too high"
    n1_precise: uint256 = self.log2(collateral_val / debt) * 10**18 / self.logAratio - 10**18 * N / 2
    assert n1_precise >= 10**18, "Debt is too high"

    return convert(n1_precise / 10**18, int256) + n0


@external
@view
def calculate_debt_n1(collateral: uint256, debt: uint256, N: uint256) -> int256:
    return self._calculate_debt_n1(collateral, debt, N)



@external
@nonreentrant('lock')
def create_loan(collateral: uint256, debt: uint256, n: uint256):
    assert self.loans[msg.sender].initial_debt == 0, "Loan already created"
    assert n >= MIN_TICKS, "Need more ticks"
    amm: address = self.amm

    n1: int256 = self._calculate_debt_n1(collateral, debt, n)
    n2: int256 = n1 + convert(n, int256)

    rate_mul: uint256 = AMM(amm).get_rate_mul()
    self.loans[msg.sender] = Loan({initial_debt: debt, rate_mul: rate_mul})
    self.total_debt.initial_debt = self.total_debt.initial_debt * rate_mul / self.total_debt.rate_mul + debt
    self.total_debt.rate_mul = rate_mul

    AMM(amm).deposit_range(msg.sender, collateral, n1, n2, False)
    ERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, amm, collateral)
    ERC20(STABLECOIN).mint(msg.sender, debt)

    log Borrow(msg.sender, collateral, debt, n1, n2)


@internal
def _add_collateral_borrow(d_collateral: uint256, d_debt: uint256, _for: address):
    debt: uint256 = 0
    rate_mul: uint256 = 0
    debt, rate_mul = self._debt(_for)
    assert debt > 0, "Loan doesn't exist"
    debt += d_debt
    amm: address = self.amm
    n: int256 = AMM(amm).active_band()
    ns: int256[2] = AMM(amm).read_user_tick_numbers(_for)
    size: uint256 = convert(ns[1] - ns[0], uint256)
    assert ns[0] > n, "Already in underwater mode"  # ns[1] >= ns[0] anyway

    collateral: uint256 = AMM(amm).get_sum_y(_for) + d_collateral
    n1: int256 = self._calculate_debt_n1(collateral, debt, size)
    assert n1 >= ns[0], "Not enough collateral"
    n2: int256 = n1 + ns[1] - ns[0]

    AMM(amm).withdraw(_for, ZERO_ADDRESS)
    AMM(amm).deposit_range(_for, collateral, n1, n2, False)
    self.loans[_for] = Loan({initial_debt: debt, rate_mul: rate_mul})

    if d_debt > 0:
        self.total_debt.initial_debt = self.total_debt.initial_debt * rate_mul / self.total_debt.rate_mul + d_debt
        self.total_debt.rate_mul = rate_mul

    log Borrow(_for, collateral, debt, n1, n2)


@external
@nonreentrant('lock')
def add_collateral(collateral: uint256, _for: address):
    self._add_collateral_borrow(collateral, 0, _for)
    ERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, self.amm, collateral)


@external
@nonreentrant('lock')
def borrow_more(collateral: uint256, debt: uint256):
    self._add_collateral_borrow(collateral, debt, msg.sender)
    ERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, self.amm, collateral)
    ERC20(STABLECOIN).mint(msg.sender, debt)


@external
@nonreentrant('lock')
def repay(_d_debt: uint256, _for: address):
    # Or repay all for MAX_UINT256
    # Withdraw if debt become 0
    debt: uint256 = 0
    rate_mul: uint256 = 0
    debt, rate_mul = self._debt(_for)
    assert debt > 0, "Loan doesn't exist"
    d_debt: uint256 = _d_debt
    if _d_debt == MAX_UINT256:
        d_debt = debt
    assert d_debt <= debt, "Repaid too much"
    ERC20(BORROWED_TOKEN).burnFrom(msg.sender, d_debt)
    debt -= d_debt

    amm: address = self.amm
    n: int256 = AMM(amm).active_band()
    ns: int256[2] = AMM(amm).read_user_tick_numbers(_for)
    size: uint256 = convert(ns[1] - ns[0], uint256)
    assert ns[0] > n, "Already in underwater mode"  # ns[1] >= ns[0] anyway

    collateral: uint256 = AMM(amm).get_sum_y(_for)
    if debt == 0:
        AMM(amm).withdraw(_for, _for)
        log Borrow(_for, 0, 0, 0, 0)
    else:
        AMM(amm).withdraw(_for, ZERO_ADDRESS)
        n1: int256 = self._calculate_debt_n1(collateral, debt, size)
        assert n1 >= ns[0], "Not enough collateral"
        n2: int256 = n1 + ns[1] - ns[0]
        AMM(amm).deposit_range(_for, collateral, n1, n2, False)
        log Borrow(_for, collateral, debt, n1, n2)

    self.loans[_for] = Loan({initial_debt: debt, rate_mul: rate_mul})
    d: uint256 = self.total_debt.initial_debt * rate_mul / self.total_debt.rate_mul
    if d <= d_debt:
        self.total_debt.initial_debt = 0
    else:
        self.total_debt.initial_debt = d - d_debt
    self.total_debt.rate_mul = rate_mul


@external
@nonreentrant('lock')
def liquidate(user: address):
    # Take all the fiat in the AMM, up to the debt size, and cancel the debt
    # Bite into collateral if underwater
    pass


@external
@nonreentrant('lock')
def self_liquidate():
    # Take all the fiat in the AMM, up to the debt size, and cancel the debt
    # Don't allow if underwater
    debt: uint256 = 0
    rate_mul: uint256 = 0
    debt, rate_mul = self._debt(msg.sender)
    assert debt > 0, "Loan doesn't exist"
    amm: address = self.amm
    xmax: uint256 = AMM(amm).get_x_down(msg.sender)
    assert xmax * (10**18 - self.liquidation_discount) / 10**18 >= debt, "Too rekt"

    # xy: uint256[2] = AMM(amm).withdraw(msg.sender, 
    # self.loans[msg.se