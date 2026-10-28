from pathlib import Path
import subprocess,shlex,sys,shutil
platform=sys.argv[1];base=Path('/Users/davidbakposada/.codex/workspaces/taskfold-acceptance');repo=base/('TasskFold-MacOS' if platform=='mac' else 'TaskFold-iOS');host=Path('/tmp/taskfold-workflow-native-mac-host' if platform=='mac' else '/tmp/taskfold-prepared-undo-signed-ios-host')
files=['Taskfold/Views/BackupTools.swift','TaskfoldUITests/TaskfoldMacUITests.swift' if platform=='mac' else 'TaskfoldUITests/TaskfoldUITests.swift','Taskfold/Core/Store.swift','Taskfold/Core/ProjectWorkflows.swift','Taskfold/Core/Models.swift','Taskfold/Core/TaskActivity.swift','Taskfold/TeamTemplateNativeFixture.swift','Taskfold/Core/AudioComments.swift','Taskfold/Views/TaskInspector.swift' if platform=='mac' else 'Taskfold/Views/TaskEditor.swift','Taskfold/AudioCommentNativeFixture.swift','Taskfold/Core/AudioCommentVault.swift','Taskfold/AudioCommentCapture.swift','Taskfold/AudioCommentMedia.swift','Taskfold/Views/AudioCommentDraftView.swift','TaskfoldUITests/AudioCommentUITests.swift','Taskfold/TaskfoldMacApp.swift' if platform=='mac' else 'Taskfold/TaskfoldApp.swift']
for f in files:
 if (repo/f).read_bytes() != (host/f).read_bytes():shutil.copy2(repo/f,host/f)
args=shlex.split(Path('/tmp/taskfold-projection-final-mac-build.log' if platform=='mac' else '/tmp/taskfold-projection-ios-build.log').read_text().splitlines()[1]);products='/tmp/taskfold-prepared-undo-signed-ios-build/Build/Products/Debug-iphonesimulator'
sign=['python3',str(repo/'Scripts/sign_simulator_test_products.py'),'--products',products,'--identity','9421BFBE87503809AB8274B2B84048C65BE9D2FC','--team','3UZ4C73FM2','--bundle-prefix','com.dbakp.taskfold.workflowteststeameditbridge']
if platform=='ios':subprocess.run(sign+['--prepare-build','--receipt','/tmp/taskfold-audio-portable-native-v4-prebuild.json'],check=True)
with open(f'/tmp/taskfold-audio-portable-native-v4-{platform}-build.log','w') as log:
 log.write('Command line invocation:\n    '+shlex.join(args)+'\n\n');log.flush();subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,check=True)
if platform=='ios':subprocess.run(sign+['--receipt','/tmp/taskfold-audio-portable-native-v4-signing.json'],check=True)
print(platform,'native build/sign passed')
