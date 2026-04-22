import pandas as pd

archivo = "HISTÓRICO DE RECIBOS 2025.26 OFICIAL.xlsx"
hojas = ["ENERO26", "FEBRERO26", "MARZO26", "ABRIL26"]

locales = set()
inquilinos = set()
contratos = {}
pagos = []

for hoja in hojas:
    print(f"Procesando hoja: {hoja}")
    df = pd.read_excel(archivo, sheet_name=hoja, header=None)

    for _, row in df.iterrows():
        nombre = str(row[0]).strip()
        local = str(row[1]).strip()

        if nombre == "nan" or local == "nan":
            continue

        locales.add(local)
        inquilinos.add(nombre)

        key = f"{nombre}|{local}"
        contratos[key] = {
            "inquilino": nombre,
            "local": local
        }

        monto_base = row[2] if not pd.isna(row[2]) else 0
        numero_recibo = row[3] if not pd.isna(row[3]) else None
        fecha = row[5] if not pd.isna(row[5]) else None
        extra1 = row[6] if len(row) > 6 and not pd.isna(row[6]) else 0
        extra2 = row[7] if len(row) > 7 and not pd.isna(row[7]) else 0

        monto_total = float(monto_base) + float(extra1) + float(extra2)

        pagos.append({
            "inquilino": nombre,
            "local": local,
            "monto_total": monto_total,
            "numero_recibo": int(numero_recibo) if numero_recibo else None,
            "fecha": str(fecha)
        })

df_locales = pd.DataFrame(sorted(list(locales)), columns=["codigo_local"])
df_inquilinos = pd.DataFrame(sorted(list(inquilinos)), columns=["nombre"])
df_contratos = pd.DataFrame(list(contratos.values()))
df_pagos = pd.DataFrame(pagos)

df_locales.to_csv("locales.csv", index=False)
df_inquilinos.to_csv("inquilinos.csv", index=False)
df_contratos.to_csv("contratos.csv", index=False)
df_pagos.to_csv("pagos.csv", index=False)

print("✅ Listo")
print(f"Locales: {len(df_locales)}")
print(f"Inquilinos: {len(df_inquilinos)}")
print(f"Contratos: {len(df_contratos)}")
print(f"Pagos: {len(df_pagos)}")
print("Archivos generados: locales.csv, inquilinos.csv, contratos.csv, pagos.csv")