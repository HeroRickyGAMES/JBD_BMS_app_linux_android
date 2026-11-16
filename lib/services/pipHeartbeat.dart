import 'package:jbd_bms_android/screens/home_screen.dart';
import 'package:simple_pip_mode/simple_pip.dart';

//Desenvolvido por HeroRickyGames
//Função de heartbeat do pipmode

void PipHeartBeat(var setstate){
  SimplePip(
      onPipEntered:(){
        isInPIP = true;
        setstate;
      },
      onPipExited: (){
        isInPIP = false;
        setstate;
      },
    ).enterPipMode();
}