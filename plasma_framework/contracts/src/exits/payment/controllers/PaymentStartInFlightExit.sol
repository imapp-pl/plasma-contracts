pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "../PaymentExitDataModel.sol";
import "../routers/PaymentInFlightExitRouterArgs.sol";
import "../spendingConditions/IPaymentSpendingCondition.sol";
import "../spendingConditions/PaymentSpendingConditionRegistry.sol";
import "../../OutputGuardParserRegistry.sol";
import "../../interfaces/IOutputGuardParser.sol";
import "../../interfaces/IStateTransitionVerifier.sol";
import "../../utils/ExitableTimestamp.sol";
import "../../utils/ExitId.sol";
import "../../utils/OutputGuard.sol";
import "../../utils/OutputId.sol";
import "../../../utils/IsDeposit.sol";
import "../../../utils/UtxoPosLib.sol";
import "../../../utils/Merkle.sol";
import "../../../framework/PlasmaFramework.sol";
import "../../../transactions/PaymentTransactionModel.sol";
import "../../../transactions/WireTransaction.sol";
import "../../../transactions/outputs/PaymentOutputModel.sol";

library PaymentStartInFlightExit {
    using ExitableTimestamp for ExitableTimestamp.Calculator;
    using IsDeposit for IsDeposit.Predicate;
    using UtxoPosLib for UtxoPosLib.UtxoPos;

    uint256 constant public MAX_INPUT_NUM = 4;

    struct Controller {
        PlasmaFramework framework;
        IsDeposit.Predicate isDeposit;
        ExitableTimestamp.Calculator exitTimestampCalculator;
        PaymentSpendingConditionRegistry spendingConditionRegistry;
        IStateTransitionVerifier transitionVerifier;
        OutputGuardParserRegistry outputGuardParserRegistry;
    }

    event InFlightExitStarted(
        address indexed initiator,
        bytes32 txHash
    );

     /**
     * @dev data to be passed around start in-flight exit helper functions
     * @param exitId ID of the exit.
     * @param inFlightTxRaw In-flight transaction as bytes.
     * @param inFlightTx Decoded in-flight transaction.
     * @param inFlightTxHash Hash of in-flight transaction.
     * @param inputTxs Input transactions as bytes.
     * @param inputUtxosPos Postions of input utxos.
     * @param inputUtxosPos Postions of input utxos coded as integers.
     * @param inputUtxosTypes Types of outputs that make in-flight transaction inputs.
     * @param outputGuardDataPreImages Output guard pre-images for in-flight transaction inputs.
     * @param inputTxsInclusionProofs Merkle proofs for input transactions.
     * @param inFlightTxWitnesses Witnesses for in-flight transactions.
     * @param outputIds Output ids for input transactions.
     */
    struct StartExitData {
        Controller controller;
        uint192 exitId;
        bytes inFlightTxRaw;
        PaymentTransactionModel.Transaction inFlightTx;
        bytes32 inFlightTxHash;
        bytes[] inputTxs;
        UtxoPosLib.UtxoPos[] inputUtxosPos;
        uint256[] inputUtxosPosRaw;
        uint256[] inputUtxosTypes;
        bytes[] outputGuardDataPreImages;
        bytes[] inputTxsInclusionProofs;
        bytes[] inFlightTxWitnesses;
        bytes32[] outputIds;
    }

    function buildController(
        PlasmaFramework framework,
        PaymentSpendingConditionRegistry registry,
        IStateTransitionVerifier transitionVerifier,
        OutputGuardParserRegistry outputGuardParserRegistry
    )
        public
        view
        returns (Controller memory)
    {
        return Controller({
            framework: framework,
            isDeposit: IsDeposit.Predicate(framework.CHILD_BLOCK_INTERVAL()),
            exitTimestampCalculator: ExitableTimestamp.Calculator(framework.minExitPeriod()),
            spendingConditionRegistry: registry,
            transitionVerifier: transitionVerifier,
            outputGuardParserRegistry: outputGuardParserRegistry
        });
    }

    function run(
        Controller memory self,
        PaymentExitDataModel.InFlightExitMap storage inFlightExitMap,
        PaymentInFlightExitRouterArgs.StartExitArgs memory args
    )
        public
    {
        StartExitData memory startExitData = createStartExitData(self, args);
        verifyStart(startExitData, inFlightExitMap);
        startExit(startExitData, inFlightExitMap);
        emit InFlightExitStarted(msg.sender, startExitData.inFlightTxHash);
    }

    function createStartExitData(
        Controller memory controller,
        PaymentInFlightExitRouterArgs.StartExitArgs memory args
    )
        private
        pure
        returns (StartExitData memory)
    {
        StartExitData memory exitData;
        exitData.controller = controller;
        exitData.exitId = ExitId.getInFlightExitId(args.inFlightTx);
        exitData.inFlightTxRaw = args.inFlightTx;
        exitData.inFlightTx = PaymentTransactionModel.decode(args.inFlightTx);
        exitData.inFlightTxHash = keccak256(args.inFlightTx);
        exitData.inputTxs = args.inputTxs;
        exitData.inputUtxosPos = decodeInputTxsPositions(args.inputUtxosPos);
        exitData.inputUtxosPosRaw = args.inputUtxosPos;
        exitData.inputUtxosTypes = args.inputUtxosTypes;
        exitData.inputTxsInclusionProofs = args.inputTxsInclusionProofs;
        exitData.outputGuardDataPreImages = args.outputGuardDataPreImages;
        exitData.inFlightTxWitnesses = args.inFlightTxWitnesses;
        exitData.outputIds = getOutputIds(controller, exitData.inputTxs, exitData.inputUtxosPos);
        return exitData;
    }

    function decodeInputTxsPositions(uint256[] memory inputUtxosPos) private pure returns (UtxoPosLib.UtxoPos[] memory) {
        require(inputUtxosPos.length <= MAX_INPUT_NUM, "Too many transactions provided");

        UtxoPosLib.UtxoPos[] memory utxosPos = new UtxoPosLib.UtxoPos[](inputUtxosPos.length);
        for (uint i = 0; i < inputUtxosPos.length; i++) {
            utxosPos[i] = UtxoPosLib.UtxoPos(inputUtxosPos[i]);
        }
        return utxosPos;
    }

    function getOutputIds(Controller memory controller, bytes[] memory inputTxs, UtxoPosLib.UtxoPos[] memory utxoPos)
        private
        pure
        returns (bytes32[] memory)
    {
        require(inputTxs.length == utxoPos.length, "Number of input transactions does not match number of provided input utxos positions");
        bytes32[] memory outputIds = new bytes32[](inputTxs.length);
        for (uint i = 0; i < inputTxs.length; i++) {
            bool isDepositTx = controller.isDeposit.test(utxoPos[i].blockNum());
            outputIds[i] = isDepositTx ?
                OutputId.computeDepositOutputId(inputTxs[i], utxoPos[i].outputIndex(), utxoPos[i].value)
                : OutputId.computeNormalOutputId(inputTxs[i], utxoPos[i].outputIndex());
        }
        return outputIds;
    }

    function verifyStart(
        StartExitData memory exitData,
        PaymentExitDataModel.InFlightExitMap storage inFlightExitMap
    )
        private
        view
    {
        verifyExitNotStarted(exitData.exitId, inFlightExitMap);
        verifyNumberOfInputsMatchesNumberOfInFlightTransactionInputs(exitData);
        verifyNoInputSpentMoreThanOnce(exitData.inFlightTx);
        verifyInputTransactionsIncludedInPlasma(exitData);
        verifyInputsSpent(exitData);
        require(
            exitData.controller.transitionVerifier.isCorrectStateTransition(exitData.inFlightTxRaw, exitData.inputTxs, exitData.inputUtxosPosRaw),
            "Invalid state transition"
        );
    }

    function verifyExitNotStarted(
        uint192 exitId,
        PaymentExitDataModel.InFlightExitMap storage inFlightExitMap
    )
        private
        view
    {
        PaymentExitDataModel.InFlightExit storage exit = inFlightExitMap.exits[exitId];
        require(exit.exitStartTimestamp == 0, "There is an active in-flight exit from this transaction");
        require(!isFinalized(exit), "This in-flight exit has already been finalized");
    }

    function isFinalized(PaymentExitDataModel.InFlightExit storage ife) private view returns (bool) {
        return Bits.bitSet(ife.exitMap, 255);
    }

    function verifyNumberOfInputsMatchesNumberOfInFlightTransactionInputs(StartExitData memory exitData) private pure {
        require(
            exitData.inputUtxosPos.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions positions does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inputUtxosTypes.length == exitData.inFlightTx.inputs.length,
            "Number of input utxo types does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inputTxsInclusionProofs.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions inclusion proofs does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inFlightTxWitnesses.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions witnesses does not match number of in-flight transaction inputs"
        );
    }

    function verifyNoInputSpentMoreThanOnce(PaymentTransactionModel.Transaction memory inFlightTx) private pure {
        if (inFlightTx.inputs.length > 1) {
            for (uint i = 0; i < inFlightTx.inputs.length; i++) {
                for (uint j = i + 1; j < inFlightTx.inputs.length; j++) {
                    require(inFlightTx.inputs[i] != inFlightTx.inputs[j], "In-flight transaction must have unique inputs");
                }
            }
        }
    }

    function verifyInputTransactionsIncludedInPlasma(StartExitData memory exitData) private view {
        for (uint i = 0; i < exitData.inputTxs.length; i++) {
            (bytes32 root, ) = exitData.controller.framework.blocks(exitData.inputUtxosPos[i].blockNum());
            bytes32 leaf = keccak256(exitData.inputTxs[i]);
            require(
                    Merkle.checkMembership(leaf, exitData.inputUtxosPos[i].txIndex(), root, exitData.inputTxsInclusionProofs[i]),
                    "Input transaction is not included in plasma"
                );
        }
    }

    function verifyInputsSpent(StartExitData memory exitData) private view {
        for (uint i = 0; i < exitData.inputTxs.length; i++) {
            uint16 outputIndex = exitData.inputUtxosPos[i].outputIndex();
            WireTransaction.Output memory output = WireTransaction.getOutput(exitData.inputTxs[i], outputIndex);

            if (exitData.inputUtxosTypes[i] != 0) {
                bytes32 outputGuardFromPreImage = OutputGuard.build(exitData.inputUtxosTypes[i], exitData.outputGuardDataPreImages[i]);
                require(output.outputGuard == outputGuardFromPreImage, "Output guard data does not match pre-image");
            }

            //FIXME: consider moving spending conditions to PlasmaFramework
            IPaymentSpendingCondition condition = exitData.controller.spendingConditionRegistry.spendingConditions(
                exitData.inputUtxosTypes[i], exitData.inFlightTx.txType
            );
            require(address(condition) != address(0), "Spending condition contract not found");

            bool isSpentByInFlightTx = condition.verify(
                output.outputGuard,
                exitData.inputUtxosPos[i].value,
                exitData.outputIds[i],
                exitData.inFlightTxRaw,
                uint8(i),
                exitData.inFlightTxWitnesses[i]
            );
            require(isSpentByInFlightTx, "Spending condition failed");
        }
    }

    function startExit(
        StartExitData memory startExitData,
        PaymentExitDataModel.InFlightExitMap storage inFlightExitMap
    )
        private
    {
        PaymentExitDataModel.InFlightExit storage ife = inFlightExitMap.exits[startExitData.exitId];
        ife.bondOwner = msg.sender;
        ife.position = getYoungestInputUtxoPosition(startExitData.inputUtxosPos);
        ife.exitStartTimestamp = block.timestamp;
        setInFlightExitInputs(ife, startExitData);
        setInFlightExitOutputs(ife, startExitData);
    }

    function getYoungestInputUtxoPosition(UtxoPosLib.UtxoPos[] memory inputUtxosPos) private pure returns (uint256) {
        uint256 youngest = inputUtxosPos[0].value;
        for (uint i = 1; i < inputUtxosPos.length; i++) {
            if (inputUtxosPos[i].value > youngest) {
                youngest = inputUtxosPos[i].value;
            }
        }
        return youngest;
    }

    function setInFlightExitInputs(
        PaymentExitDataModel.InFlightExit storage ife,
        StartExitData memory exitData
    )
        private
    {
        for (uint i = 0; i < exitData.inputTxs.length; i++) {
            uint16 outputIndex = exitData.inputUtxosPos[i].outputIndex();
            WireTransaction.Output memory output = WireTransaction.getOutput(exitData.inputTxs[i], outputIndex);

            address payable exitTarget;
            if (exitData.inputUtxosTypes[i] == 0) {
                // output type 0 --> output holding owner address directly
                exitTarget = AddressPayable.convert(address(uint256(output.outputGuard)));
            } else if (exitData.inputUtxosTypes[i] != 0) {
                IOutputGuardParser outputGuardParser = exitData.controller.outputGuardParserRegistry.outputGuardParsers(exitData.inputUtxosTypes[i]);
                require(address(outputGuardParser) != address(0), "Failed to get the output guard parser for the output type");
                exitTarget = outputGuardParser.parseExitTarget(exitData.outputGuardDataPreImages[i]);
            }

            ife.inputs[i] = PaymentExitDataModel.WithdrawData(
                exitData.outputIds[i],
                exitTarget,
                output.token,
                output.amount
            );
        }
    }

    function setInFlightExitOutputs(
        PaymentExitDataModel.InFlightExit storage ife,
        StartExitData memory exitData
    )
        private
    {
        for (uint i = 0; i < exitData.inFlightTx.outputs.length; i++) {
            // deposit transaction can't be in-flight exited
            bytes32 outputId = OutputId.computeNormalOutputId(exitData.inFlightTxRaw, i);
            PaymentOutputModel.Output memory output = exitData.inFlightTx.outputs[i];

            ife.outputs[i] = PaymentExitDataModel.WithdrawData(
                outputId,
                address(0),
                output.token,
                output.amount
            );
        }
    }
}
