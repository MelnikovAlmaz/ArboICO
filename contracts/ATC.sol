pragma solidity ^0.4.18;
import "./ERC20.sol";
import "./MiniMeToken.sol";

contract ATC is MiniMeToken {
    // @dev ATC constructor just parametrizes the MiniMeIrrevocableVestedToken constructor
    function ATC() MiniMeToken(
    "ArboCar Token", // Token name
    18,                     // Decimals
    "ATC",                  // Symbol
    true                    // Enable transfers
    ) {}
}