package com.quall.android.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.annotation.DrawableRes
import androidx.recyclerview.widget.RecyclerView
import com.quall.android.R
import com.quall.android.core.QuallBrowser
import com.quall.android.databinding.ItemDeviceBinding

/**
 * Aparelhos Quall achados na LAN pelo mDNS do núcleo: a lista "NA REDE AGORA" de Exibir, a "PROMPTERS
 * NA REDE" de Controlar e a crua do diagnóstico.
 *
 * Pelo fluxo de `docs/fluxo-de-uso.md`, quem exibe escolhe aqui e conecta. Cada linha
 * (`docs/telas-estudio.md` §6.6): o ícone, o nome, o endereço em mono e o selo PAREADO quando o anúncio
 * traz o id de um par conhecido ([pareados]; sem id, sem selo, §11.1). [detalhado]: a lista do
 * diagnóstico, que mostra também os papéis e a versão do protocolo.
 */
class DeviceListAdapter(
    /** Os ids dos pares conhecidos (lidos a cada desenho: um pareamento novo aparece na próxima lista). */
    private val pareados: () -> Set<String> = { emptySet() },
    @DrawableRes private val icone: Int = R.drawable.ic_q_espelhar,
    private val detalhado: Boolean = false,
    private val onTap: (QuallBrowser.Device) -> Unit,
) : RecyclerView.Adapter<DeviceListAdapter.ViewHolder>() {

    private val items = ArrayList<QuallBrowser.Device>()

    fun submit(devices: List<QuallBrowser.Device>) {
        items.clear()
        items.addAll(devices)
        notifyDataSetChanged()
    }

    class ViewHolder(val binding: ItemDeviceBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val binding = ItemDeviceBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return ViewHolder(binding)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        val device = items[position]
        val b = holder.binding
        // O contexto da Activity que inflou a linha: fala o idioma escolhido (`docs/traducao.md`, Android).
        val ctx = b.root.context
        val nome = device.displayName.ifBlank { device.deviceId }
        b.textDeviceName.text = nome
        b.iconeDoAparelho.setImageResource(icone)
        val endereco = device.endpoint ?: ctx.getString(R.string.rx_sem_endereco)
        b.textDeviceDetail.text = if (detalhado) {
            val papeis = buildList {
                if (device.papel == com.quall.android.core.Papeis.TELEPROMPTER) add(ctx.getString(R.string.rx_papel_teleprompter))
                if (device.screenSource) add(ctx.getString(R.string.rx_papel_tela))
                if (device.cameraSource) add(ctx.getString(R.string.rx_papel_camera))
                if (device.sink) add(ctx.getString(R.string.rx_papel_exibe))
            }.joinToString(", ").ifBlank { ctx.getString(R.string.rx_sem_capacidade) }
            "$endereco · $papeis · v${device.protocolVersion}"
        } else {
            endereco
        }
        val pareado = device.deviceId.isNotBlank() && device.deviceId in pareados()
        b.seloPareado.visibility = if (pareado) View.VISIBLE else View.GONE
        b.root.contentDescription =
            nome + (if (pareado) ", " + ctx.getString(R.string.rx_pareado_falado) else "") + ", " + endereco
        b.root.setOnClickListener { onTap(device) }
    }

    override fun getItemCount(): Int = items.size
}
