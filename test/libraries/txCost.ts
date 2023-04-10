import { ethers } from "hardhat";

const getTXReceipt = async (tx: ethers.ContractTransaction) => await tx.wait();
const getTXCostFromReciept = (txReciept: ethers.ContractReceipt) => (txReciept.cumulativeGasUsed).mul(txReciept.effectiveGasPrice);

export const getTXCost = async (tx: ethers.ContractTransaction) => getTXCostFromReciept(await getTXReceipt(tx));