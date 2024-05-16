function deploy-contracts
	 # Build bytecode from source
	 cd ~/code/onramp-contracts
	 forge build
	 set bcProver (get-bytecode out/Prover.sol/DealClient.json)
	 set bcOracle (get-bytecode out/Oracles.sol/ForwardingProofMockBridge.json)
	 set bcOnRamp (get-bytecode out/OnRamp.sol/OnRampContract.json)

	 # Deploy contracts to local network
	 cd ~/code/lotus
	 echo $bcProver > prover.bytecode
	 echo $bcOracle > oracle.bytecode
	 echo $bcOnRamp > onramp.bytecode
	 set proverOut (./lotus evm deploy --hex prover.bytecode)
	 set oracleOut (./lotus evm deploy --hex oracle.bytecode)
	 set onrampOut (./lotus evm deploy --hex onramp.bytecode)

	 set proverAddr (parse-address $proverOut)
	 set oracleAddr (parse-address $oracleOut)
	 set onrampAddr (parse-address $onrampOut)
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
end

#  $argv[1] path to compiled file
function get-bytecode
	 # Strip extra jq quotes and "0x" and beginning 
	 jq '.bytecode.object' $argv[1] | sed -e 's/0x//g ; s/\"//g'
end

#  $argv string output of lotus evm deploy 
function parse-address
	 echo $argv | grep -oP "Eth Address: \K0x[a-f0-9]+"
end

function parse-id-address
	 echo $argv | grep -oP "ID Address: \K(t|f)[0-9]+"
end

function deploy-tokens
	 cd ~/code/onramp-contracts
	 forge build
	 set bcNickle (get-bytecode out/Token.sol/Nickle.json)
	 set bcCowry (get-bytecode out/Token.sol/BronzeCowry.json)
	 set bcPound (get-bytecode out/Token.sol/DebasedTowerPoundSterling.json)

	 cd ~/code/lotus
	 echo $bcNickle > nickle.bytecode
	 echo $bcCowry > cowry.bytecode
	 echo $bcPound > pound.bytecode

	 ascii-five
	 echo -e "~$0.05~$0.05~ 'NICKLE' ~$0.05~$0.05~\n"
	 ./lotus evm deploy --hex nickle.bytecode

	 ascii-shell
	 echo -e "~#!~#!~ 'SHELL' ~#!~#!~\n"	 
	 ./lotus evm deploy --hex cowry.bytecode

	 ascii-union-jack	 
	 echo -e "~#L~#L~ 'NEWTON' ~#L~#L~\n"
	 ./lotus evm deploy --hex pound.bytecode
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