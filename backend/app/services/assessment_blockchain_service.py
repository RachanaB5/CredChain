"""
Service for anchoring and verifying AI assessment records on-chain
via the AssessmentRegistry.sol smart contract.
"""

import json
import logging
import os
from typing import Any, Dict, Optional
from web3 import Web3

logger = logging.getLogger(__name__)

# Default Anvil Configuration
RPC_URL = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
ASSESSMENT_REGISTRY_ADDRESS = os.environ.get(
    "ASSESSMENT_REGISTRY_ADDRESS",
    "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
)
DEFAULT_RECORDER_KEY = os.environ.get(
    "RECORDER_PRIVATE_KEY",
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
)

# Load ABI
ASSESSMENT_REGISTRY_ABI = None
_abi_paths = [
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "blockchain", "out", "AssessmentRegistry.sol", "AssessmentRegistry.json"),
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))), "blockchain", "out", "AssessmentRegistry.sol", "AssessmentRegistry.json"),
]

for p in _abi_paths:
    if os.path.exists(p):
        try:
            with open(p, "r") as f:
                artifact = json.load(f)
                ASSESSMENT_REGISTRY_ABI = artifact.get("abi", [])
            break
        except Exception as e:
            logger.warning("Could not load ABI from %s: %s", p, e)

STATUS_TO_ENUM = {
    "UNVERIFIED": 0,
    "EVIDENCE_CHECKED": 1,
    "SOURCE_VERIFIED": 2,
    "MANUAL_REVIEW": 3,
}

def get_web3_client() -> Web3:
    return Web3(Web3.HTTPProvider(RPC_URL))

def _to_bytes32(val: Optional[str]) -> bytes:
    if not val:
        return b"\x00" * 32
    clean = val[2:] if val.startswith("0x") else val
    # Remove hyphens if UUID
    clean = clean.replace("-", "")
    # Pad to 64 hex characters (32 bytes)
    clean = clean.ljust(64, "0")[:64]
    return bytes.fromhex(clean)

def anchor_assessment_on_chain(
    assessment_id: str,
    borrower_address: str,
    assessment_hash: str,
    previous_assessment_hash: Optional[str],
    model_version: str,
    verification_status: str,
    risk_category: str,
) -> Optional[str]:
    """
    Submits recordAssessment() transaction to AssessmentRegistry.sol.
    Returns the transaction hash or None if offline or error.
    """
    try:
        w3 = get_web3_client()
        if not w3.is_connected() or not ASSESSMENT_REGISTRY_ABI:
            logger.warning("Web3 not connected or missing ASSESSMENT_REGISTRY_ABI; skipping on-chain anchor.")
            return None

        contract = w3.eth.contract(
            address=Web3.to_checksum_address(ASSESSMENT_REGISTRY_ADDRESS),
            abi=ASSESSMENT_REGISTRY_ABI,
        )
        recorder_account = w3.eth.account.from_key(DEFAULT_RECORDER_KEY)
        nonce = w3.eth.get_transaction_count(recorder_account.address)

        assessment_id_bytes = _to_bytes32(assessment_id)
        assessment_hash_bytes = bytes.fromhex(assessment_hash[2:] if assessment_hash.startswith("0x") else assessment_hash)
        prev_hash_bytes = (
            bytes.fromhex(previous_assessment_hash[2:] if previous_assessment_hash.startswith("0x") else previous_assessment_hash)
            if previous_assessment_hash
            else b"\x00" * 32
        )
        borrower_checksum = Web3.to_checksum_address(borrower_address)
        status_code = STATUS_TO_ENUM.get(verification_status.upper(), 0)

        tx = contract.functions.recordAssessment(
            assessment_id_bytes,
            borrower_checksum,
            assessment_hash_bytes,
            prev_hash_bytes,
            model_version,
            status_code,
            risk_category,
        ).build_transaction({
            "from": recorder_account.address,
            "nonce": nonce,
            "gas": 350000,
            "gasPrice": w3.eth.gas_price,
        })

        signed = w3.eth.account.sign_transaction(tx, private_key=DEFAULT_RECORDER_KEY)
        tx_hash_bytes = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash_bytes, timeout=15)

        if receipt.status == 1:
            tx_hash_hex = "0x" + receipt.transactionHash.hex().replace("0x", "")
            logger.info("Successfully recorded assessment %s on-chain (tx: %s)", assessment_id, tx_hash_hex)
            return tx_hash_hex
        else:
            logger.error("On-chain recording failed with status 0 for assessment %s", assessment_id)
            return None
    except Exception as e:
        logger.error("Failed to anchor assessment %s on-chain: %s", assessment_id, e)
        return None

def verify_assessment_on_chain(assessment_id: str, expected_hash: str) -> Dict[str, Any]:
    """
    Queries AssessmentRegistry.sol to verify if the given assessment hash matches on-chain.
    """
    try:
        w3 = get_web3_client()
        if not w3.is_connected() or not ASSESSMENT_REGISTRY_ABI:
            return {"verified": False, "error": "Blockchain client not connected"}

        contract = w3.eth.contract(
            address=Web3.to_checksum_address(ASSESSMENT_REGISTRY_ADDRESS),
            abi=ASSESSMENT_REGISTRY_ABI,
        )

        assessment_id_bytes = _to_bytes32(assessment_id)
        expected_hash_bytes = bytes.fromhex(expected_hash[2:] if expected_hash.startswith("0x") else expected_hash)

        is_valid = contract.functions.verifyAssessmentHash(
            assessment_id_bytes,
            expected_hash_bytes,
        ).call()

        record = contract.functions.getAssessment(assessment_id_bytes).call()

        return {
            "verified": is_valid,
            "assessment_id": assessment_id,
            "on_chain_hash": "0x" + record[0].hex(),
            "previous_hash": "0x" + record[1].hex() if record[1] != b"\x00" * 32 else None,
            "borrower": record[2],
            "model_version": record[3],
            "timestamp": record[4],
            "verification_status": record[5],
            "risk_category": record[6],
            "version": record[7],
        }
    except Exception as e:
        logger.error("Failed to verify assessment %s on-chain: %s", assessment_id, e)
        return {"verified": False, "error": str(e)}
