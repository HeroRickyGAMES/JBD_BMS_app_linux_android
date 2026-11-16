import 'package:jbd_bms_android/screens/home_screen.dart';
import 'package:simple_pip_mode/actions/pip_action.dart';
import 'package:simple_pip_mode/simple_pip.dart';

//Desenvolvido por HeroRickyGames
//Função de heartbeat do pipmode

void AutoPip(void setstate){
  SimplePip(
      onPipEntered:(){
        isInPIP = true;
        setstate;
      },
      onPipExited: (){
        isInPIP = false;
        setstate;
      },
      onPipAction: (PipAction ac){
        print("debugando $ac");
      }
    ).setAutoPipMode();
}
