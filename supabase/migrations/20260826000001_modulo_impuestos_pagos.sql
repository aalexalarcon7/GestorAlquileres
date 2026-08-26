-- =====================================================
-- MODULO IMPUESTOS Y PAGOS
-- Recordatorios administrativos del Jefe
-- Independiente de alquileres / inquilinos / contratos
-- =====================================================

CREATE TABLE IF NOT EXISTS public.recordatorios_pagos (
    id BIGSERIAL PRIMARY KEY,

    titulo TEXT NOT NULL,

    categoria TEXT NOT NULL,

    descripcion TEXT,

    monto NUMERIC(12,2) DEFAULT 0,

    fecha_vencimiento DATE NOT NULL,

    estado TEXT NOT NULL DEFAULT 'PENDIENTE'
    CHECK (
        estado IN (
            'PENDIENTE',
            'PAGADO',
            'VENCIDO'
        )
    ),

    periodicidad TEXT NOT NULL DEFAULT 'UNICO'
    CHECK (
        periodicidad IN (
            'UNICO',
            'MENSUAL',
            'ANUAL'
        )
    ),

    recordatorio_dias INTEGER DEFAULT 5,

    fecha_pago DATE,

    observacion TEXT,

    activo BOOLEAN DEFAULT true,

    created_at TIMESTAMPTZ DEFAULT now(),

    updated_at TIMESTAMPTZ DEFAULT now()
);


CREATE INDEX IF NOT EXISTS idx_recordatorios_pagos_fecha
ON public.recordatorios_pagos(fecha_vencimiento);


CREATE INDEX IF NOT EXISTS idx_recordatorios_pagos_estado
ON public.recordatorios_pagos(estado);


CREATE INDEX IF NOT EXISTS idx_recordatorios_pagos_categoria
ON public.recordatorios_pagos(categoria);



ALTER TABLE public.recordatorios_pagos
ENABLE ROW LEVEL SECURITY;



CREATE POLICY "solo jefe puede gestionar recordatorios pagos"
ON public.recordatorios_pagos
FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.usuarios_operativos u
        WHERE u.email = auth.jwt()->>'email'
        AND u.rol = 'JEFE'
        AND u.activo = true
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM public.usuarios_operativos u
        WHERE u.email = auth.jwt()->>'email'
        AND u.rol = 'JEFE'
        AND u.activo = true
    )
);



CREATE OR REPLACE FUNCTION public.actualizar_updated_at_recordatorios()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;



CREATE TRIGGER trigger_updated_at_recordatorios
BEFORE UPDATE ON public.recordatorios_pagos
FOR EACH ROW
EXECUTE FUNCTION public.actualizar_updated_at_recordatorios();



GRANT ALL ON TABLE public.recordatorios_pagos
TO authenticated;


GRANT USAGE, SELECT
ON SEQUENCE public.recordatorios_pagos_id_seq
TO authenticated;
