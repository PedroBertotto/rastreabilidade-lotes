// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  Rastreabilidade de lotes agroalimentares para cooperativas
/// @notice Protótipo do TCC II – Blockchain e Rastreabilidade (UNOCHAPECÓ)
/// @dev    Modelo "cooperativa valida e registra": o produtor envia os dados
///         à cooperativa (fora da blockchain) e somente a cooperativa grava
///         na rede, como no diagrama BPMN do TCC I (lane "Cooperativa").
///         Dados sensíveis ficam off-chain; na blockchain vai só o hash
///         (keccak256) do documento, o que permite provar integridade sem
///         expor dados pessoais (LGPD).
contract RastreabilidadeLotes {
    // ---------------------------------------------------------------
    // Tipos
    // ---------------------------------------------------------------
    enum Etapa {
        Producao,        // 0 - registro inicial do lote
        Sanitario,       // 1 - vacinação, medicamentos, laudos
        Transporte,      // 2 - coleta / frete
        Recebimento,     // 3 - recebimento na cooperativa
        Processamento,   // 4 - industrialização / abate
        Expedicao        // 5 - saída para o mercado
    }

    struct Lote {
        bytes32 id;             // identificador único (vira o QR Code)
        string  codigoInterno;  // código do lote no sistema da cooperativa
        string  tipoProduto;    // leite, frango, suíno, grãos...
        address produtor;       // carteira que representa o produtor
        uint64  dataProducao;   // unix timestamp da produção/colheita/abate
        uint64  registradoEm;   // block.timestamp do registro
        bool    existe;
    }

    struct Evento {
        Etapa   etapa;
        bytes32 hashDados;      // hash do documento off-chain (0x0 se não houver)
        string  descricao;      // resumo curto e não sensível
        address responsavel;    // quem assinou a transação
        uint64  timestamp;
    }

    // ---------------------------------------------------------------
    // Estado
    // ---------------------------------------------------------------
    address public cooperativa;
    mapping(address => bool) public produtoresAutorizados;

    mapping(bytes32 => Lote)     private lotes;
    mapping(bytes32 => Evento[]) private historico;
    bytes32[] private listaLotes;

    // ---------------------------------------------------------------
    // Eventos (logs consultáveis no Etherscan)
    // ---------------------------------------------------------------
    event ProdutorAtualizado(address indexed produtor, bool autorizado);
    event LoteRegistrado(bytes32 indexed id, string codigoInterno, address indexed produtor);
    event EventoRegistrado(bytes32 indexed id, Etapa etapa, bytes32 hashDados);

    // ---------------------------------------------------------------
    // Controle de acesso
    // ---------------------------------------------------------------
    modifier somenteCooperativa() {
        require(msg.sender == cooperativa, "Apenas a cooperativa");
        _;
    }

    modifier loteExiste(bytes32 id) {
        require(lotes[id].existe, "Lote inexistente");
        _;
    }

    constructor() {
        cooperativa = msg.sender; // quem faz o deploy representa a cooperativa
    }

    // ---------------------------------------------------------------
    // Escrita (custam gas)
    // ---------------------------------------------------------------
    function definirProdutor(address produtor, bool autorizado) external somenteCooperativa {
        require(produtor != address(0), "Endereco invalido");
        produtoresAutorizados[produtor] = autorizado;
        emit ProdutorAtualizado(produtor, autorizado);
    }

    /// @notice Registra um lote já validado pela cooperativa.
    /// @return id Identificador único do lote (usado no QR Code).
    function registrarLote(
        string calldata codigoInterno,
        string calldata tipoProduto,
        address produtor,
        uint64 dataProducao,
        bytes32 hashDadosIniciais
    ) external somenteCooperativa returns (bytes32 id) {
        require(produtoresAutorizados[produtor], "Produtor nao autorizado");
        require(bytes(codigoInterno).length > 0, "Codigo obrigatorio");
        require(bytes(tipoProduto).length > 0, "Tipo obrigatorio");
        require(dataProducao <= block.timestamp, "Data no futuro");

        id = keccak256(abi.encode(codigoInterno, produtor, dataProducao));
        require(!lotes[id].existe, "Lote ja registrado");

        lotes[id] = Lote({
            id: id,
            codigoInterno: codigoInterno,
            tipoProduto: tipoProduto,
            produtor: produtor,
            dataProducao: dataProducao,
            registradoEm: uint64(block.timestamp),
            existe: true
        });
        listaLotes.push(id);

        historico[id].push(Evento({
            etapa: Etapa.Producao,
            hashDados: hashDadosIniciais,
            descricao: "Registro inicial do lote",
            responsavel: msg.sender,
            timestamp: uint64(block.timestamp)
        }));

        emit LoteRegistrado(id, codigoInterno, produtor);
        emit EventoRegistrado(id, Etapa.Producao, hashDadosIniciais);
    }

    /// @notice Acrescenta uma etapa ao histórico. Nada é sobrescrito:
    ///         correções entram como um novo evento (trilha de auditoria).
    function registrarEvento(
        bytes32 id,
        Etapa etapa,
        bytes32 hashDados,
        string calldata descricao
    ) external somenteCooperativa loteExiste(id) {
        require(etapa != Etapa.Producao, "Producao ja registrada");
        historico[id].push(Evento({
            etapa: etapa,
            hashDados: hashDados,
            descricao: descricao,
            responsavel: msg.sender,
            timestamp: uint64(block.timestamp)
        }));
        emit EventoRegistrado(id, etapa, hashDados);
    }

    // ---------------------------------------------------------------
    // Leitura (gratuitas – usadas pela consulta do QR Code)
    // ---------------------------------------------------------------
    function consultarLote(bytes32 id) external view loteExiste(id) returns (Lote memory) {
        return lotes[id];
    }

    function consultarHistorico(bytes32 id) external view loteExiste(id) returns (Evento[] memory) {
        return historico[id];
    }

    /// @notice Auditor recalcula o hash do documento que recebeu e confere
    ///         se é idêntico ao que foi registrado (prova de integridade).
    function verificarDocumento(bytes32 id, uint256 indiceEvento, bytes32 hashCalculado)
        external view loteExiste(id) returns (bool)
    {
        require(indiceEvento < historico[id].length, "Evento inexistente");
        return historico[id][indiceEvento].hashDados == hashCalculado;
    }

    function totalLotes() external view returns (uint256) {
        return listaLotes.length;
    }

    function loteNaPosicao(uint256 i) external view returns (bytes32) {
        return listaLotes[i];
    }
}
