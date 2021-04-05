import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'
import { id } from '@yield-protocol/utils'
import { BigNumber } from 'ethers'
import { WAD } from './shared/constants'

import JoinArtifact from '../artifacts/contracts/Join.sol/Join.json'
import ERC20MockArtifact from '../artifacts/contracts/mocks/ERC20Mock.sol/ERC20Mock.json'
import FlashBorrowerArtifact from '../artifacts/contracts/mocks/FlashBorrower.sol/FlashBorrower.json'

import { Join } from '../typechain/Join'
import { ERC20Mock } from '../typechain/ERC20Mock'
import { FlashBorrower } from '../typechain/FlashBorrower'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { deployContract } = waffle

describe('Join - flash', function () {
  this.timeout(0)

  let ownerAcc: SignerWithAddress
  let owner: string
  let otherAcc: SignerWithAddress
  let other: string
  let join: Join
  let joinFromOther: Join
  let token: ERC20Mock
  let borrower: FlashBorrower

  const actions = {
    none: '0x0000000000000000000000000000000000000000000000000000000000000000',
    transfer: '0x0000000000000000000000000000000000000000000000000000000000000001',
    steal: '0x0000000000000000000000000000000000000000000000000000000000000002',
    reenter: '0x0000000000000000000000000000000000000000000000000000000000000003',
  }

  before(async () => {
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = await ownerAcc.getAddress()

    otherAcc = signers[1]
    other = await otherAcc.getAddress()
  })

  beforeEach(async () => {
    token = (await deployContract(ownerAcc, ERC20MockArtifact, ['MTK', 'Mock Token'])) as ERC20Mock
    join = (await deployContract(ownerAcc, JoinArtifact, [token.address])) as Join
    joinFromOther = join.connect(otherAcc)

    await join.grantRoles(
      [id('join(address,uint128)'), id('exit(address,uint128)'), id('setFlashFeeFactor(uint256)')],
      owner
    )

    await token.mint(join.address, WAD.mul(100))
    await join.join(owner, 0)

    borrower = (await deployContract(ownerAcc, FlashBorrowerArtifact, [join.address])) as FlashBorrower
  })

  it('the receiver needs to approve the repayment', async () => {
    await expect(join.flashLoan(borrower.address, token.address, WAD, actions.none)).to.be.revertedWith(
      'ERC20: Insufficient approval'
    )
  })

  it('should do a simple flash loan', async () => {
    await borrower.flashBorrow(token.address, WAD, actions.none)

    expect(await token.balanceOf(owner)).to.equal(0)
    expect(await borrower.flashBalance()).to.equal(WAD)
    expect(await borrower.flashToken()).to.equal(token.address)
    expect(await borrower.flashAmount()).to.equal(WAD)
    expect(await borrower.flashInitiator()).to.equal(borrower.address)
  })

  it('can repay the flash loan by transfer', async () => {
    await expect(borrower.flashBorrow(token.address, WAD, actions.transfer))
      .to.emit(token, 'Transfer')
      .withArgs(borrower.address, join.address, WAD)

    expect(await token.balanceOf(owner)).to.equal(0)
    expect(await borrower.flashBalance()).to.equal(WAD)
    expect(await borrower.flashToken()).to.equal(token.address)
    expect(await borrower.flashAmount()).to.equal(WAD)
    expect(await borrower.flashInitiator()).to.equal(borrower.address)
  })

  it('needs to have enough funds to repay a flash loan', async () => {
    await expect(borrower.flashBorrow(token.address, WAD, actions.steal)).to.be.revertedWith(
      'ERC20: Insufficient balance'
    )
  })

  it('should do two nested flash loans', async () => {
    await borrower.flashBorrow(token.address, WAD, actions.reenter) // It will borrow WAD, and then reenter and borrow WAD * 2
    expect(await borrower.flashBalance()).to.equal(WAD.mul(3))
  })

  it('sets the flash fee factor', async () => {
    const feeFactor = BigNumber.from(10).pow(25).mul(5) // 5%
    await expect(join.setFlashFeeFactor(feeFactor)).to.emit(join, 'FlashFeeFactorSet').withArgs(feeFactor)
    expect(await join.flashFeeFactor()).to.equal(feeFactor)
  })

  describe('with a non-zero fee', async () => {
    beforeEach(async () => {
      const feeFactor = BigNumber.from(10).pow(25).mul(5) // 5%
      await join.setFlashFeeFactor(feeFactor)
    })

    it('should do a simple flash loan', async () => {
      const principal = WAD
      const fee = principal.mul(5).div(100)
      await token.mint(borrower.address, fee)
      await expect(borrower.flashBorrow(token.address, principal, actions.none))
        .to.emit(token, 'Transfer')
        .withArgs(borrower.address, join.address, principal.add(fee))

      expect(await token.balanceOf(owner)).to.equal(0)
      expect(await borrower.flashBalance()).to.equal(principal.add(fee))
      expect(await borrower.flashToken()).to.equal(token.address)
      expect(await borrower.flashAmount()).to.equal(principal)
      expect(await borrower.flashInitiator()).to.equal(borrower.address)
    })
  })
})