pragma solidity ^0.4.18;

import "./SafeMath.sol";
import "./Controller.sol";
import "./ATC.sol";
import "./SaleWallet.sol";

/*
    Copyright 2017, Jorge Izquierdo (Aragon Foundation)
    Copyright 2017, Jordi Baylina (Giveth)

    Based on SampleCampaign-TokenController.sol from https://github.com/Giveth/minime
 */

contract ATCTokenSale is Controller, SafeMath {
    uint public initialBlock;             // Block number in which the sale starts. Inclusive. sale will be opened at initial block.
    uint public finalBlock;               // Block number in which the sale end. Exclusive, sale will be closed at ends block.
    address public aragonDevMultisig;     // The address to hold the funds donated
    uint8 priceStages;
    address private creator;

    uint public totalCollected = 0;               // In wei
    uint private presaleToken = 0;                 // Amount of tokens generated while pre-sale
    bool public saleStopped = false;              // Has Aragon Dev stopped the sale?
    bool public saleFinalized = false;            // Has Aragon Dev finalized the sale?

    mapping (address => bool) public activated;   // Address confirmates that wants to activate the sale

    ATC public token;                             // The token
    SaleWallet private saleWallet;                    // Wallet that receives all sale funds

    uint constant private dust = 1 finney;         // Minimum investment
    uint private hardCap = 1000000 ether;          // Hard cap to protect the ETH network from a really high raise

    event NewPresaleAllocation(address indexed holder, uint256 antAmount);
    event NewBuyer(address indexed holder, uint256 antAmount, uint256 etherAmount);
    event CapRevealed(uint value, uint secret, address revealer);
    /// @dev There are several checks to make sure the parameters are acceptable
    /// @param _initialBlock The Block number in which the sale starts
    /// @param _finalBlock The Block number in which the sale ends
    /// @param _aragonDevMultisig The address that will store the donated funds and manager
    /// for the sale
    /// will be linearly interpolated.

    function ATCTokenSale (
    uint _initialBlock,
    uint _finalBlock,
    address _aragonDevMultisig
    )
    non_zero_address(_aragonDevMultisig)
    {
        if (_initialBlock < getBlockNumber()) revert();
        if (_initialBlock >= _finalBlock) revert();

        // Save constructor arguments as global variables
        initialBlock = _initialBlock;
        finalBlock = _finalBlock;
        aragonDevMultisig = _aragonDevMultisig;
        priceStages = 4;
        creator = msg.sender;
    }

    // @notice Deploy ANT is called only once to setup all the needed contracts.
    // @param _token: Address of an instance of the ANT token
    // @param _saleWallet: Address of the wallet receiving the funds of the sale

    function setANT(address _token, address _saleWallet)
    non_zero_address(_token)
    non_zero_address(_saleWallet)
    only(creator)
    public {

        // Assert that the function hasn't been called before, as activate will happen at the end
        if (activated[this]) revert();

        token = ATC(_token);
        saleWallet = SaleWallet(_saleWallet);

        if (token.controller() != address(this)) revert(); // sale is controller
        if (token.totalSupply() > 0) revert(); // token is empty
        if (saleWallet.finalBlock() != finalBlock) revert(); // final blocks must match
        if (saleWallet.multisig() != aragonDevMultisig) revert(); // receiving wallet must match
        if (saleWallet.tokenSale() != address(this)) revert(); // watched token sale must be self

        // Contract activates sale as all requirements are ready
        doActivateSale(this);
    }

    // @notice Certain addresses need to call the activate function prior to the sale opening block.
    // This proves that they have checked the sale contract is legit, as well as proving
    // the capability for those addresses to interact with the contract.
    function activateSale()
    public {
        doActivateSale(msg.sender);
    }

    function doActivateSale(address _entity)
    non_zero_address(token)               // cannot activate before setting token
    only_before_sale
    private {
        activated[_entity] = true;
    }

    // @notice Whether the needed accounts have activated the sale.
    // @return Is sale activated
    function isActivated() constant public returns (bool) {
        return activated[this] && activated[creator];
    }

    // @notice Method shows balance of passed address
    // @return Number of tokens in wallet

    function getBalance(address _owner) constant public returns (uint256){
        return token.balanceOf(_owner);
    }

    // @notice Get the price for a ANT token at any given block number
    // @param _blockNumber the block for which the price is requested
    // @return Number of wei-ANT for 1 wei
    // If sale isn't ongoing for that block, returns 0.
    function getPrice() constant public returns (uint256) {
        uint _supply = token.totalSupply();

        return priceForStage(stageForSupply(_supply));
    }

    // @notice Get what the stage is for a given blockNumber
    // @param _blockNumber: Block number
    // @return The sale stage for that block. Stage is between 0 and (priceStages - 1)
    function stageForSupply(uint _supply) constant internal returns (uint8) {
        uint generatedTokens = _supply - presaleToken;
        uint8 _stage = 1;
        if (generatedTokens >= 0 && generatedTokens <= 30000000 ether){
            _stage = 1;
        }
        if (generatedTokens > 30000000 ether && generatedTokens <= 46500000 ether){
            _stage = 2;
        }
        if (generatedTokens > 46500000 ether && generatedTokens <= 57000000 ether){
            _stage = 3;
        }
        if (generatedTokens > 57000000 ether && generatedTokens <= 60000000 ether){
            _stage = 4;
        }
        if (generatedTokens > 60000000 ether){
            _stage = 5;
        }
        return _stage;
    }

    // @notice Get what the price is for a given stage
    // @param _stage: Stage number
    // @return Price in ether for that stage.
    // If sale stage doesn't exist, returns 0.
    function priceForStage(uint8 _stage) constant internal returns (uint256) {
        if (_stage >= priceStages) return 0;
        uint _price = 0;
        if(_stage == 1){
            _price = 0.08333 ether;
        }
        if(_stage == 2){
            _price = 0.089285714 ether;
        }
        if(_stage == 3){
            _price = 0.094339623 ether;
        }
        if(_stage == 4){
            _price = 0.1 ether;
        }
        return _price;
    }

    // @notice Aragon Dev needs to make initial token allocations for presale partners
    // This allocation has to be made before the sale is activated. Activating the sale means no more
    // arbitrary allocations are possible and expresses conformity.
    // @param _receiver: The receiver of the tokens
    // @param _amount: Amount of tokens allocated for receiver.
    function allocatePresaleTokens(address _receiver, uint _amount)
    only_before_sale_activation
    only_before_sale
    non_zero_address(_receiver)
    only(creator)
    public {

        if (_amount > 10 ** 24) revert(); // 1 million ANT. No presale partner will have more than this allocated. Prevent overflows.

        if (!token.generateTokens(_receiver, _amount)) revert();
        presaleToken += _amount;

        NewPresaleAllocation(_receiver, _amount);
    }

    /// @dev The fallback function is called when ether is sent to the contract, it
    /// simply calls `doPayment()` with the address that sent the ether as the
    /// `_owner`. Payable is a required solidity modifier for functions to receive
    /// ether, without this modifier functions will throw if ether is sent to them

    function invest() public payable {
        return doPayment(msg.sender);
    }

    /////////////////
    // Controller interface
    /////////////////

    /// @notice `proxyPayment()` allows the caller to send ether to the Token directly and
    /// have the tokens created in an address of their choosing
    /// @param _owner The address that will hold the newly created tokens

    function proxyPayment(address _owner) payable public returns (bool) {
        doPayment(_owner);
        return true;
    }

    /// @notice Notifies the controller about a transfer, for this sale all
    ///  transfers are allowed by default and no extra notifications are needed
    /// @param _from The origin of the transfer
    /// @param _to The destination of the transfer
    /// @param _amount The amount of the transfer
    /// @return False if the controller does not authorize the transfer
    function onTransfer(address _from, address _to, uint _amount) public returns (bool) {
        // Until the sale is finalized, only allows transfers originated by the sale contract.
        // When finalizeSale is called, this function will stop being called and will always be true.
        return _from == address(this);
    }

    /// @notice Notifies the controller about an approval, for this sale all
    ///  approvals are allowed by default and no extra notifications are needed
    /// @param _owner The address that calls `approve()`
    /// @param _spender The spender in the `approve()` call
    /// @param _amount The amount in the `approve()` call
    /// @return False if the controller does not authorize the approval
    function onApprove(address _owner, address _spender, uint _amount) public returns (bool) {
        // No approve/transferFrom during the sale
        return false;
    }

    /// @dev `doPayment()` is an internal function that sends the ether that this
    ///  contract receives to the aragonDevMultisig and creates tokens in the address of the
    /// @param _owner The address that will hold the newly created tokens

    function doPayment(address _owner)
    only_during_sale_period
    only_sale_not_stopped
    only_sale_activated
    non_zero_address(_owner)
    minimum_value(dust)
    internal {

        if (totalCollected + msg.value > hardCap) revert(); // If past hard cap, throw

        uint256 boughtTokens = safeDiv(msg.value, getPrice()); // Calculate how many tokens bought

        if (!saleWallet.send(msg.value)) revert(); // Send funds to multisig
        if (!token.generateTokens(_owner, boughtTokens * 1 ether)) revert(); // Allocate tokens. This will fail after sale is finalized in case it is hidden cap finalized.

        totalCollected = safeAdd(totalCollected, msg.value); // Save total collected amount

        NewBuyer(_owner, boughtTokens, msg.value);
    }

    // @notice Function to stop sale for an emergency.
    // @dev Only Aragon Dev can do it after it has been activated.
    function emergencyStopSale()
    only_sale_activated
    only_sale_not_stopped
    only(creator)
    public {

        saleStopped = true;
    }

    // @notice Function to restart stopped sale.
    // @dev Only Aragon Dev can do it after it has been disabled and sale is ongoing.
    function restartSale()
    only_during_sale_period
    only_sale_stopped
    only(creator)
    public {

        saleStopped = false;
    }

    function revealCap()
    only_during_sale_period
    only_sale_activated
    public {

        if (totalCollected + dust >= hardCap) {
            doFinalizeSale();
        }
    }

    // @notice Finalizes sale generating the tokens for Aragon Dev.
    // @dev Transfers the token controller power to the ANPlaceholder.
    function finalizeSale()
    only(creator)
    public {

        doFinalizeSale();
    }

    function doFinalizeSale()
    internal {
        // Doesn't check if saleStopped is false, because sale could end in a emergency stop.
        // This function cannot be successfully called twice, because it will top being the controller,
        // and the generateTokens call will fail if called again.

        // Aragon Dev owns 30% of the total number of emitted tokens at the end of the sale.
        uint256 aragonTokens = token.totalSupply() * 3 / 7;
        if (!token.generateTokens(aragonDevMultisig, aragonTokens)) revert();

        saleFinalized = true;  // Set stop is true which will enable network deployment
        saleStopped = true;
    }


    function setAragonDevMultisig(address _newMultisig)
    non_zero_address(_newMultisig)
    only(creator)
    public {

        aragonDevMultisig = _newMultisig;
    }

    function getBlockNumber() constant internal returns (uint) {
        return block.number;
    }


    modifier only(address x) {
        if (msg.sender != x) revert();
        _;
    }


    modifier only_before_sale {
        if (getBlockNumber() >= initialBlock) revert();
        _;
    }

    modifier only_during_sale_period {
        if (getBlockNumber() < initialBlock) revert();
        if (getBlockNumber() >= finalBlock) revert();
        _;
    }

    modifier only_after_sale {
        if (getBlockNumber() < finalBlock) revert();
        _;
    }

    modifier only_sale_stopped {
        if (!saleStopped) revert();
        _;
    }

    modifier only_sale_not_stopped {
        if (saleStopped) revert();
        _;
    }

    modifier only_before_sale_activation {
        if (isActivated()) revert();
        _;
    }

    modifier only_sale_activated {
        if (!isActivated()) revert();
        _;
    }

    modifier only_finalized_sale {
        if (getBlockNumber() < finalBlock) revert();
        if (!saleFinalized) revert();
        _;
    }

    modifier non_zero_address(address x) {
        if (x == 0) revert();
        _;
    }

    modifier minimum_value(uint256 x) {
        if (msg.value < x) revert();
        _;
    }
}
