from ape import project, accounts
from ape.cli import NetworkBoundCommand, account_option, network_option
import click
import typing

SHORT_NAME = "crvUSD"
FULL_NAME = "Curve.Fi USD Stablecoin"


def deploy_blueprint(contract, account):
    initcode = contract.contract_type.deployment_bytecode.bytecode
    if isinstance(initcode, str):
        initcode = bytes.fromhex(initcode.removeprefix("0x"))
    initcode = b"\xfe\x71\x00" + initcode  # eip-5202 preamble version 0
    initcode = (
        b"\x61" + len(initcode).to_bytes(2, "big") + b"\x3d\x81\x60\x0a\x3d\x39\xf3" + initcode
    )
    tx = project.provider.network.ecosystem.create_transaction(
        chain_id=project.provider.chain_id,
        data=initcode,
        gas_price=project.provider.gas_price,
        nonce=account.nonce,
    )
    tx.gas_limit = project.provider.estimate_gas_cost(tx)
    tx.signature = account.sign_transaction(tx)
    receipt = project.provider.send_transaction(tx)
    click.echo(f"blueprint deployed at: {receipt.contract_address}")
    return receipt.contract_address


@click.group()
def cli():
    """
    Command-line helper for managing Smartwallet Checker
    """


@cli.command(
    cls=NetworkBoundCommand,
    name="deploy",
)
@network_option()
@account_option()
def main(network, account):
    
    if not network == "ethereum:mainnet-fork":
        raise NotImplementedError("Mainnet not implemented yet")
    else:
        admin = account
        fee_receiver = account

    stablecoin = account.deploy(project.Stablecoin, FULL_NAME, SHORT_NAME)
    factory = account.deploy(project.ControllerFactory, stablecoin, admin, fee_receiver)

    controller_impl = deploy_blueprint(project.Controller, account)
    amm_impl = deploy_blueprint(project.AMM, account)

    factory.set_implementations(controller_impl, amm_impl, sender=account)
    stablecoin.set_minter(factory.address, sender=account)

    if network == "ethereum:mainnet-fork":
        policy = account.deploy(project.ConstantMonetaryPolicy, admin)
        policy.set_rate(0, sender=account)  # 0%
        price_oracle = account.deploy(project.DummyPriceOracle, admin, 3000 * 10**18)
        collateral_token = account.deploy(project.ERC20Mock, 'Collateral WETH', 'WETH', 18)

    factory.add_market(
        collateral_token, 100, 10**16, 0,
        price_oracle,
        policy, 5 * 10**16, 2 * 10**16,
        10**6 * 10**18,
        sender=account
    )

    amm = project.AMM.at(factory.get_amm(collateral_token))
    controller = project.Controller.at(factory.get_controller(collateral_token))

    if network == "ethereum:mainnet-fork":
        for user in accounts:
            collateral_token._mint_for_testing(user, 10**4 * 10**18, sender=account)

    print('========================')
    print('Stablecoin:  ', stablecoin.address)
    print('Factory:     ', factory.address)
    print('Collateral:  ', collateral_token.address)
    print('AMM:         ', amm.address)
    print('Controller:  ', controller.address)