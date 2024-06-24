# how to use
1. install dependencies
```
yarn
```

2.  run tests

copy config.example.js to config.js and set required variables

```
hh test
```
3. deploy
```
hh run scripts/<name of deploy script>
```

# testnet deployment
{
  factory: '0xf089a68AcB2Ac39c136DEFBF469201487622de69',
  router: '0x146Fc64706a91e3C10539CBe317AbC4b859335c7',
  token: '0xBba4f9c1838837246452D3504981066b27D883e5',
  masterChef: '0x059217D0AC3a29577e3449E32225E9Dfa9755ec7',
  usdc: '0x82fa51b3B9d4E2ccbdB902851B598FAe70c93809',
  weth: '0xCbd7a2Db5F38fad25352c3279A8535EB7137dd39',
  sushi: '0x43fA137808c0469C82E63fB418b4D8f58279A2f1',
  lfgWethLp: '0x99F6f025ae923A97ABbe599900b282FADdF0b69D',
  sushiWethLp: '0x3418780d3CA86C299FFeB8d4fF5E9509f0dD127e',
  usdcWethPairAddress: '0x9Abb53F7549d3fa8FBF87EED068c3E2b95Ec8329'
}