# Set ONRAMP_CODE_PATH, LOTUS_EXEC_PATH, and XCHAIN_KEY_PATH before calling
# Deploys contracts needed for onramp demo
# Sets up config for data-client and xchain-connector
function deploy-onramp
	# Build bytecode from source
	cd $ONRAMP_CODE_PATH
	cd ~/code/onramp-contracts
	forge build
	set bcProver (get-bytecode out/Prover.sol/DealClient.json)
	set bcOracle (get-bytecode out/Oracles.sol/ForwardingProofMockBridge.json)
	set bcOnRamp (get-bytecode out/OnRamp.sol/OnRampContract.json)

	# Deploy contracts to local network
	cd $LOTUS_EXEC_PATH
	echo $bcProver > prover.bytecode
	echo $bcOracle > oracle.bytecode
	echo $bcOnRamp > onramp.bytecode
	set proverOut (./lotus evm deploy --hex prover.bytecode)
	set oracleOut (./lotus evm deploy --hex oracle.bytecode)
	set onrampOut (./lotus evm deploy --hex onramp.bytecode)

	set -x proverAddr (parse-address $proverOut)
	set -x oracleAddr (parse-address $oracleOut)
	set -x onrampAddr (parse-address $onrampOut)
	set proverIDAddr (parse-id-address $proverOut)
	set oracleIDAddr (parse-id-address $oracleOut)
	set onrampIDAddr (parse-id-address $onrampOut)


	# Print out Info
	echo -e "~*~*~Oracle~*~*~\n"
	string join \n $oracleOut[3..]
	echo -e "\n"
	echo -e "~*~*~Prover~*~*~\n"
	string join \n $proverOut[3..]
	echo -e "\n"	 
	echo -e "~*~*~OnRamp~*~*~\n"
	string join \n $onrampOut[3..]
	echo -e "\n"

	# Wire contracts up together
	echo -e "~*~*~Connect Oracle to Prover\n"
	set calldataProver (cast calldata "setBridgeContract(address)" $oracleAddr)
	./lotus evm invoke $proverIDAddr $calldataProver

	echo -e "\n~*~*~Connect Oracle to OnRamp\n"
	set calldataOnRamp (cast calldata "setOracle(address)" $oracleAddr)
	./lotus evm invoke $onrampIDAddr $calldataOnRamp

	echo -e "\n~*~*~Connect Prover and OnRamp to Oracle\n"
	set callDataOracle (cast calldata "setSenderReceiver(string,address)" $proverAddr $onrampAddr)
	./lotus evm invoke $oracleIDAddr $callDataOracle

	# Setup xchain config
	mkdir -p ~/.xchain

	cd $LOTUS_EXEC_PATH
	# Parse address from eth keystore file 
	set clientAddr (cat $XCHAIN_KEY_PATH | jq '.address' | sed -e 's/\"//g')
	set filClientAddr (parse-filecoin-addr (./lotus evm stat $clientAddr))

	./lotus state wait-msg --timeout "2m" (./lotus send $filClientAddr 10000)
	cd $ONRAMP_CODE_PATH
	jq -c '.abi' out/OnRamp.sol/OnRampContract.json > ~/.xchain/onramp-abi.json

	jo -a (jo -- ChainID=314 Api="ws://localhost:1234/rpc/v1" -s OnRampAddress="$onrampAddr" KeyPath="$XCHAIN_KEY_PATH" ClientAddr="$clientAddr" OnRampABIPath=~/.xchain/onramp-abi.json) > ~/.xchain/config.json
	echo "config written to ~/.xchain/config.json" 
	deploy-tokens $clientAddr
end

#  $argv[1] path to compiled file
function get-bytecode
	 # Strip extra jq quotes and "0x" 
	 jq '.bytecode.object' $argv[1] | sed -e 's/0x//g ; s/\"//g'
end

#  $argv string output of lotus evm deploy 
function parse-address
	 echo $argv | grep -oP "Eth Address: \K0x[a-f0-9]+"
end

function parse-id-address
	 echo $argv | grep -oP "ID Address: \K(t|f)[0-9]+"
end

function parse-filecoin-address
	echo $argv | grep -oP "Filecoin address: \K0x[a-f0-9]+"
end

function deploy-tokens
	 cd $ONRAMP_CODE_PATH
	 forge build
	 set bcNickle (get-bytecode out/Token.sol/Nickle.json)
	 set bcCowry (get-bytecode out/Token.sol/BronzeCowry.json)
	 set bcPound (get-bytecode out/Token.sol/DebasedTowerPoundSterling.json)

	 cd $LOTUS_EXEC_PATH
	 echo $bcNickle > nickle.bytecode
	 echo $bcCowry > cowry.bytecode
	 echo $bcPound > pound.bytecode

	 ascii-five
	 echo -e "~$0.05~$0.05~ 'NICKLE' ~$0.05~$0.05~\n"
	 # TODO lets see if we can --from an eth addr or if we need to parse-filecoin-addr first
	 ./lotus evm deploy --from $argv[1] --hex nickle.bytecode

	 ascii-shell
	 echo -e "~#!~#!~ 'SHELL' ~#!~#!~\n"	 
	 ./lotus evm deploy --from $argv[1] --hex cowry.bytecode

	 ascii-union-jack	 
	 echo -e "~#L~#L~ 'NEWTON' ~#L~#L~\n"
	 ./lotus evm deploy --from $argv[1] --hex pound.bytecode
end

# Some ASCII logos to give our erc20s character
function ascii-five
	 echo "
                 ____  
                | ___| 
                |___ \ 
                 ___) |
                |____/ 

"
end

function ascii-shell
	 echo -e "
                  /\\
                 {.-}
                ;_,-'\\
               {    _.}_      
                \.-' /  `,
                 \  |    /
                  \ |  ,/
                   \|_/

"
end

function ascii-union-jack
	 echo -e "
⢿⣦⣌⠙⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⣿⣿⣿⡇⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠋⣡⣴⡿
⣦⡈⠛⢿⣶⣄⡙⠻⣿⣿⣿⣿⣿⣿⠀⣿⣿⣿⡇⣿⣿⣿⣿⣿⣿⠟⢋⣠⣶⡿⠛⢁⣤
⣿⣿⣷⣤⡈⠛⢿⣶⣄⡙⠻⢿⣿⣿⠀⣿⣿⣿⡇⣿⣿⣿⠟⢋⣠⣶⡿⠛⢁⣤⣾⣿⣿
⣿⣿⣿⣿⣿⣷⣦⣈⠙⠿⠷⠤⠉⠻⠀⣿⣿⣿⡇⠟⠉⠤⠾⠿⠋⣁⣤⣾⣿⣿⣿⣿⣿
⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣿⣿⣿⣇⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⣿⣿⣿⡿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿⠿
⣿⣿⣿⣿⣿⣿⠟⠋⣀⣴⡶⠖⢀⣤⠀⣿⣿⣿⡇⣤⡀⠲⢶⣦⣄⠙⠻⣿⣿⣿⣿⣿⣿
⣿⣿⣿⠟⠋⣠⣴⡿⠟⢉⣤⣾⣿⣿⠀⣿⣿⣿⡇⣿⣿⣷⣤⡉⠻⢿⣦⣄⠙⠻⣿⣿⣿
⠟⠋⣠⣴⡿⠛⣉⣤⣾⣿⣿⣿⣿⣿⠀⣿⣿⣿⡇⣿⣿⣿⣿⣿⣷⣤⣈⠛⢿⣦⣄⡙⠻
⣶⠿⠛⣁⣴⣾⣿⣿⣿⣿⣿⣿⣿⣿⠀⣿⣿⣿⡇⣿⣿⣿⣿⣿⣿⣿⣿⣷⣦⣈⠙⠿⣶


	 "

end