import "@nomicfoundation/hardhat-toolbox";
import "hardhat-gas-reporter";

const config = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
        details: {
          yul: true,
          stackAllocation: true,
          optimizerSteps: "dhfoDgvulfnTUtnIf"
        }
      },
      viaIR: true,
      evmVersion: "cancun"
    }
  },
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
      accounts: {
        count: 10,
        mnemonic: "test test test test test test test test test test test junk"
      }
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      chainId: 11155111,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : []
    },
    arbitrum: {
      url: process.env.ARBITRUM_RPC_URL || "",
      chainId: 42161,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : []
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  mocha: {
    timeout: 100000
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS ? true : false,
    currency: "USD"
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      arbitrum: process.env.ARBITRUM_API_KEY || ""
    }
  }
};

export default config;