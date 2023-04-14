let addresses = require(`/Users/zandent/Files/conflux_proj/swappi-v2/swappi-deploy/contractAddressPublicTestnet.json`);
async function main() {
    console.log(`Verifying contract on Etherscan...`);
    try {
        await hre.run(`verify:verify`, {
            address: addresses.UniswapV3StakerImpl,
            constructorArguments: [],
    });
    } catch (error) {}
    console.log(`Done for UniswapV3StakerImpl`);  
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});