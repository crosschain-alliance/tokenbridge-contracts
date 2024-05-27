pragma solidity 0.4.24;

import "../upgradeability/EternalStorage.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "./Validatable.sol";
import "../libraries/Message.sol";
import "./BasicBridge.sol";
import "./BasicTokenBridge.sol";

/**
 * @title BasicHomeBridge
 * @dev This contract implements common functionality for all vanilla bridge modes on the Home side.
 */
contract BasicHomeBridge is EternalStorage, Validatable, BasicBridge, BasicTokenBridge {
    using SafeMath for uint256;

    event UserRequestForSignature(address recipient, uint256 value, bytes32 nonce);
    event AffirmationCompleted(address recipient, uint256 value, bytes32 nonce);
    event SignedForUserRequest(address indexed signer, bytes32 messageHash);
    event SignedForAffirmation(address indexed signer, bytes32 nonce);
    event CollectedSignatures(
        address authorityResponsibleForRelay,
        bytes32 messageHash,
        uint256 NumberOfCollectedSignatures
    );

    /**
     * @dev Executes a message affirmation for some Foreign side event.
     * Can be called only by a current bridge validator.
     * @param recipient tokens/coins of receiver address, where the assets should be unlocked/minted.
     * @param value amount of assets to unlock/mint.
     * @param nonce reference nonce on the Foreign side of the bridge.
     */
    function executeAffirmation(address recipient, uint256 value, bytes32 nonce) external {
        _onlyValidator();
        bytes32 hashMsg = keccak256(abi.encodePacked(recipient, value, nonce));
        if (withinExecutionLimit(value)) {
            bytes32 hashSender = keccak256(abi.encodePacked(msg.sender, hashMsg));
            // Duplicated affirmations
            require(!affirmationsSigned(hashSender));
            setAffirmationsSigned(hashSender, true);

            uint256 signed = numAffirmationsSigned(hashMsg);
            require(!isAlreadyProcessed(signed));
            // the check above assumes that the case when the value could be overflew will not happen in the addition operation below
            signed = signed + 1;

            setNumAffirmationsSigned(hashMsg, signed);

            emit SignedForAffirmation(msg.sender, nonce);

            // NOTE: If Hashi is optional, an affirmation can be executed even if it hasn't been approved by Hashi
            if (HASHI_IS_ENABLED && HASHI_IS_MANDATORY) require(isApprovedByHashi(hashMsg));

            if (signed >= requiredSignatures()) {
                // If the bridge contract does not own enough tokens to transfer
                // it will couse funds lock on the home side of the bridge
                setNumAffirmationsSigned(hashMsg, markAsProcessed(signed));
                if (value > 0) {
                    require(onExecuteAffirmation(recipient, value, nonce, hashMsg));
                }
                emit AffirmationCompleted(recipient, value, nonce);
            }
        } else {
            onFailedAffirmation(recipient, value, nonce, hashMsg);
        }
    }

    function onMessage(uint256 chainId, uint256, address sender, bytes message) external returns (bytes) {
        require(
            HASHI_IS_ENABLED &&
                msg.sender == hashiManager().yaru() &&
                chainId == hashiManager().hashiTargetChainId() &&
                sender == hashiManager().hashiTargetAddress()
        );

        bytes32 hashMsg = keccak256(message);
        _setHashiApprovalForMessage(hashMsg, true);
    }

    function submitSignature(bytes signature, bytes message) external {
        _onlyValidator();
        // ensure that `signature` is really `message` signed by `msg.sender`
        require(Message.isMessageValid(message));
        require(msg.sender == Message.recoverAddressFromSignedMessage(signature, message, false));
        bytes32 hashMsg = keccak256(abi.encodePacked(message));
        bytes32 hashSender = keccak256(abi.encodePacked(msg.sender, hashMsg));

        uint256 signed = numMessagesSigned(hashMsg);
        require(!isAlreadyProcessed(signed));
        // the check above assumes that the case when the value could be overflew will not happen in the addition operation below
        signed = signed + 1;
        if (signed > 1) {
            // Duplicated signatures
            require(!messagesSigned(hashSender));
        } else {
            setMessages(hashMsg, message);
        }
        setMessagesSigned(hashSender, true);

        bytes32 signIdx = keccak256(abi.encodePacked(hashMsg, (signed - 1)));
        setSignatures(signIdx, signature);

        setNumMessagesSigned(hashMsg, signed);

        emit SignedForUserRequest(msg.sender, hashMsg);

        uint256 reqSigs = requiredSignatures();
        if (signed >= reqSigs) {
            setNumMessagesSigned(hashMsg, markAsProcessed(signed));
            emit CollectedSignatures(msg.sender, hashMsg, reqSigs);

            onSignaturesCollected(message);
        }
    }

    function _emitUserRequestForSignatureMaybeRelayDataWithHashiAndIncreaseNonce(address _receiver, uint256 _amount)
        internal
    {
        uint256 currentNonce = nonce();
        emit UserRequestForSignature(_receiver, _amount, bytes32(currentNonce));
        _maybeRelayDataWithHashi(abi.encodePacked(_receiver, _amount, bytes32(currentNonce)));
        setNonce(currentNonce + 1);
    }

    function setMessagesSigned(bytes32 _hash, bool _status) internal {
        boolStorage[keccak256(abi.encodePacked("messagesSigned", _hash))] = _status;
    }

    /* solcov ignore next */
    function onExecuteAffirmation(address, uint256, bytes32, bytes32) internal returns (bool);

    /* solcov ignore next */
    function onFailedAffirmation(address, uint256, bytes32, bytes32) internal;

    /* solcov ignore next */
    function onSignaturesCollected(bytes) internal;

    function numAffirmationsSigned(bytes32 _withdrawal) public view returns (uint256) {
        return uintStorage[keccak256(abi.encodePacked("numAffirmationsSigned", _withdrawal))];
    }

    function setAffirmationsSigned(bytes32 _withdrawal, bool _status) internal {
        boolStorage[keccak256(abi.encodePacked("affirmationsSigned", _withdrawal))] = _status;
    }

    function setNumAffirmationsSigned(bytes32 _withdrawal, uint256 _number) internal {
        uintStorage[keccak256(abi.encodePacked("numAffirmationsSigned", _withdrawal))] = _number;
    }

    function affirmationsSigned(bytes32 _withdrawal) public view returns (bool) {
        return boolStorage[keccak256(abi.encodePacked("affirmationsSigned", _withdrawal))];
    }

    function signature(bytes32 _hash, uint256 _index) external view returns (bytes) {
        bytes32 signIdx = keccak256(abi.encodePacked(_hash, _index));
        return bytesStorage[keccak256(abi.encodePacked("signatures", signIdx))];
    }

    function messagesSigned(bytes32 _message) public view returns (bool) {
        return boolStorage[keccak256(abi.encodePacked("messagesSigned", _message))];
    }

    function setSignatures(bytes32 _hash, bytes _signature) internal {
        bytesStorage[keccak256(abi.encodePacked("signatures", _hash))] = _signature;
    }

    function setMessages(bytes32 _hash, bytes _message) internal {
        bytesStorage[keccak256(abi.encodePacked("messages", _hash))] = _message;
    }

    function message(bytes32 _hash) external view returns (bytes) {
        return bytesStorage[keccak256(abi.encodePacked("messages", _hash))];
    }

    function setNumMessagesSigned(bytes32 _message, uint256 _number) internal {
        uintStorage[keccak256(abi.encodePacked("numMessagesSigned", _message))] = _number;
    }

    function markAsProcessed(uint256 _v) internal pure returns (uint256) {
        return _v | (2**255);
    }

    function isAlreadyProcessed(uint256 _number) public pure returns (bool) {
        return _number & (2**255) == 2**255;
    }

    function numMessagesSigned(bytes32 _message) public view returns (uint256) {
        return uintStorage[keccak256(abi.encodePacked("numMessagesSigned", _message))];
    }
}
