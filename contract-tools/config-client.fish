# First argument is address of on ramp contract
function config-client
    mkdir -p ~/.onramp
    mkdir -p ~/.onramp/keystore

    cd $LOTUS_EXEC_PATH
    set -x filClientAddr (./lotus wallet new)
    ./lotus wallet send $filClientAddr 10000 
    set keyJson (./lotus wallet export $filAddr |  xxd -r -p | jq .)
    cd $ONRAMP_CODE_PATH
    set abiJson (jq -c '.abi' out/OnRamp.sol/OnRampContract.json | jq -sR . )
    echo $keyJson > ~/.onramp/keystore/demo

    # Write config 
    jo -a (jo -- ChainID=314 Api="localhost:1234" -s OnRampAddress="$argv[1]" KeyPath=~/.onramp/keystore/demo OnRampABI="$abiJson") > ~/.onramp/config.json
end
