# Huawei E173 Portable Manager (Flutter для Windows)

Портативная Windows-программа на Flutter для USB 3G-модема **Huawei E173** в папке `flutter_app/`.

## Автоматическая сборка на GitHub Actions
После нажатия **Push changes to GitHub** откройте вкладку **Actions** в репозитории:
1. Workflow `.github/workflows/build-windows-portable.yml` запустится автоматически на `windows-latest`.
2. Через 3–5 минут в разделе **Artifacts** появится готовый архив `huawei_e173_manager-portable-win64.zip`.
3. Распакуйте его в любую папку (или на флешку) и запустите `huawei_e173_manager.exe` или `Start_Portable.bat`.
